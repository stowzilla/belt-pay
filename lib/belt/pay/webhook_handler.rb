# frozen_string_literal: true

module Belt
  module Pay
    # Handles incoming webhooks from the payment provider.
    # Verifies signatures, dispatches events, and records transactions.
    module WebhookHandler
      # Stripe events #dispatch acts on. `belt pay:setup` subscribes new webhook
      # endpoints to exactly this list.
      EVENTS = %w[
        checkout.session.completed
        checkout.session.async_payment_succeeded
        checkout.session.async_payment_failed
        checkout.session.expired
        invoice.paid
        invoice.payment_failed
        customer.subscription.created
        customer.subscription.updated
        customer.subscription.deleted
        charge.refunded
        charge.dispute.created
        charge.dispute.closed
      ].freeze

      # Checkout Session payment_status values that mean the money is in. A session
      # paid by a delayed method (bank debit, voucher) completes as `unpaid`; its
      # result arrives later as checkout.session.async_payment_succeeded / _failed.
      PAID_STATUSES = %w[paid no_payment_required].freeze

      class << self
        # Process a raw webhook request.
        # @param payload [String] Raw request body
        # @param signature [String] Provider signature header
        # @return [Hash] { received: true }
        def process(payload:, signature:)
          event = Belt::Pay.provider.verify_webhook(payload, signature)
          dispatch(event)
          { received: true }
        end

        private

        # Does the gem's bookkeeping for the event, then runs the app's Belt::Pay.on
        # hooks with the event and the transaction it touched (nil when none).
        # Stripe delivers at least once, so both halves are safe to repeat: the
        # bookkeeping changes nothing the second time, and hooks should check
        # `transaction.status` rather than assume the event is news.
        def dispatch(event)
          event_type = event['type'] || event.type

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: received event', event_type: event_type)

          transaction =
            case event_type
            when 'checkout.session.completed'
              handle_checkout_completed(event.data.object)
            when 'checkout.session.async_payment_succeeded'
              handle_checkout_async_payment_succeeded(event.data.object)
            when 'checkout.session.async_payment_failed'
              handle_checkout_async_payment_failed(event.data.object)
            when 'checkout.session.expired'
              handle_checkout_expired(event.data.object)
            when 'invoice.paid'
              handle_invoice_paid(event.data.object)
            when 'invoice.payment_failed'
              handle_invoice_payment_failed(event.data.object)
            when 'customer.subscription.deleted'
              handle_subscription_deleted(event.data.object)
            when 'customer.subscription.created', 'customer.subscription.updated'
              handle_subscription_updated(event.data.object)
            when 'charge.refunded'
              handle_charge_refunded(event.data.object)
            when 'charge.dispute.created'
              handle_dispute_created(event.data.object)
            when 'charge.dispute.closed'
              handle_dispute_closed(event.data.object)
            else
              Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: unhandled event type', event_type: event_type)
              nil
            end

          Belt::Pay.run_hooks(event_type, event, transaction)
        end

        # The session is finished, which is not the same as paid: only a paid session
        # (PAID_STATUSES) completes the transaction. An unpaid one stays pending until
        # checkout.session.async_payment_succeeded or _failed says how it went.
        def handle_checkout_completed(session)
          payment_status = value(session, :payment_status).to_s
          paid = PAID_STATUSES.include?(payment_status)
          transaction = settle_checkout(session, paid ? 'completed' : 'pending')

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: checkout completed',
                        customer_id: app_customer_id(session), session_id: value(session, :id),
                        amount_cents: value(session, :amount_total), payment_status: payment_status)
          transaction
        end

        def handle_checkout_async_payment_succeeded(session)
          transaction = settle_checkout(session, 'completed')
          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: checkout payment succeeded',
                        customer_id: app_customer_id(session), session_id: value(session, :id))
          transaction
        end

        def handle_checkout_async_payment_failed(session)
          transaction = settle_checkout(session, 'failed', description: 'Checkout payment failed')
          Belt::Pay.log(:warn, 'Belt::Pay::WebhookHandler: checkout payment failed',
                        customer_id: app_customer_id(session), session_id: value(session, :id))
          transaction
        end

        def handle_checkout_expired(session)
          transaction = settle_checkout(session, 'failed', description: 'Checkout session expired', create: false)
          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: checkout expired', session_id: value(session, :id))
          transaction
        end

        # Move a session's transaction to `status`, recording it first when the
        # webhook is the first to hear of the session. Only a pending transaction
        # moves, so a redelivered event, or one sent again from the Dashboard after
        # a refund, changes nothing and never adds a row.
        # @return [Transaction, nil]
        def settle_checkout(session, status, description: nil, create: true)
          session_id = value(session, :id)
          transaction = Transaction.for_session(session_id)
          transaction ||= record_checkout(session, status) if create
          return transaction unless transaction && transaction.status == 'pending' && status != 'pending'

          transaction.status = status
          transaction.amount_cents = value(session, :amount_total) if status == 'completed'
          transaction.currency = value(session, :currency) || transaction.currency
          transaction.provider_payment_intent_id = reference_id(value(session, :payment_intent)) ||
                                                   transaction.provider_payment_intent_id
          transaction.description = description if description
          transaction.save!
          transaction
        end

        # Webhook-first flow: no pending row for the session. Keyed on the session
        # id; when another delivery got there first, that row is the answer.
        def record_checkout(session, status)
          customer_id = app_customer_id(session)
          return nil unless customer_id

          session_id = value(session, :id)
          Transaction.record_checkout(
            customer_id: customer_id,
            session_id: session_id,
            amount_cents: value(session, :amount_total) || 0,
            currency: value(session, :currency) || 'usd',
            status: status == 'completed' ? 'completed' : 'pending',
            payment_intent_id: reference_id(value(session, :payment_intent)),
            metadata: { payment_status: value(session, :payment_status) }
          ) || Transaction.lookup(session_id)
        end

        def handle_invoice_paid(invoice)
          subscription_id = invoice_subscription_id(invoice)
          # Try to resolve customer from subscription metadata if not on invoice
          customer_id = app_customer_id(invoice) || resolve_customer_from_subscription(subscription_id)
          return unless customer_id && subscription_id

          invoice_id = value(invoice, :id)
          # Keyed on the invoice id: a redelivered invoice.paid finds the row it made.
          transaction = Transaction.record_renewal(
            id: invoice_id,
            customer_id: customer_id,
            subscription_id: subscription_id,
            amount_cents: value(invoice, :amount_paid) || 0,
            currency: value(invoice, :currency) || 'usd',
            metadata: { invoice_id: invoice_id, billing_reason: value(invoice, :billing_reason) }
          ) || Transaction.lookup(invoice_id)

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: invoice paid',
                        customer_id: customer_id, subscription_id: subscription_id,
                        amount_cents: value(invoice, :amount_paid))
          transaction
        end

        def handle_invoice_payment_failed(invoice)
          customer_id = app_customer_id(invoice) ||
                        resolve_customer_from_subscription(invoice_subscription_id(invoice))

          Belt::Pay.log(:warn, 'Belt::Pay::WebhookHandler: invoice payment failed',
                        customer_id: customer_id, invoice_id: value(invoice, :id))
          nil
        end

        def handle_subscription_deleted(subscription)
          customer_id = app_customer_id(subscription)
          return unless customer_id

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: subscription deleted',
                        customer_id: customer_id, subscription_id: value(subscription, :id))
          sync_subscription(subscription)
        end

        def handle_subscription_updated(subscription)
          customer_id = app_customer_id(subscription)
          return unless customer_id

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: subscription updated',
                        customer_id: customer_id, subscription_id: value(subscription, :id),
                        status: value(subscription, :status))
          sync_subscription(subscription)
        end

        # Bring the customer's plan and the subscription's transaction in step with
        # the subscription. The event says what was true when it was sent, and
        # events can arrive late, out of order or again, so Stripe is asked what is
        # true now. A Stripe error is raised and the event retried.
        # @return [Transaction, nil]
        def sync_subscription(event_subscription)
          subscription = Belt::Pay.provider.retrieve_subscription(value(event_subscription, :id))
          customer_id = app_customer_id(subscription) || app_customer_id(event_subscription)
          status = value(subscription, :status).to_s

          sync_customer_plan(subscription, customer_id, status)
          settle_subscription(value(subscription, :id), status)
        end

        # `pay_plan` is what Billable#plan, #plan_allows? and #within_limit? read, so
        # it is set when the subscription is active or trialing and taken back when
        # it is canceled, unpaid or expired before its first payment. Other statuses
        # (incomplete, past_due, paused) leave it as it is.
        def sync_customer_plan(subscription, customer_id, status)
          active = Subscription::ACTIVE_STATUSES.include?(status)
          return unless active || Subscription::ENDED_STATUSES.include?(status)

          customer = find_customer(customer_id)
          return unless customer.respond_to?(:pay_plan=) && customer.respond_to?(:pay_subscription_id=)

          subscription_id = value(subscription, :id)
          current = customer.pay_subscription_id.to_s
          # Only the customer's own subscription moves their plan: not an older one
          # ending after they took out a new one.
          return if !current.empty? && current != subscription_id
          return if !active && current.empty?

          plan_key = subscription_plan_key(subscription)
          before = [customer.pay_subscription_id, customer.pay_plan]
          if active
            customer.pay_subscription_id = subscription_id
            customer.pay_plan = plan_key if plan_key
          else
            # Take back the plan this subscription granted, not one held another way.
            customer.pay_plan = nil if plan_key.nil? || customer.pay_plan.to_s == plan_key
            customer.pay_subscription_id = nil unless status == 'unpaid'
          end
          return if before == [customer.pay_subscription_id, customer.pay_plan]

          customer.save(validate: false)
          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: customer plan updated',
                        customer_id: customer_id, subscription_id: subscription_id,
                        status: status, pay_plan: customer.pay_plan)
        end

        # The transaction Subscription.create recorded under the subscription id:
        # completed once the subscription is active, failed if it expired unpaid,
        # canceled when it ends.
        def settle_subscription(subscription_id, status)
          transaction = Transaction.lookup(subscription_id)
          return nil unless transaction

          target = if Subscription::ACTIVE_STATUSES.include?(status) then 'completed'
                   elsif status == 'incomplete_expired' then 'failed'
                   elsif status == 'canceled' then 'canceled'
                   end
          movable = target == 'canceled' ? %w[pending completed] : %w[pending]
          if target && movable.include?(transaction.status)
            transaction.status = target
            transaction.save!
          end
          transaction
        end

        # The declared plan a subscription is for: the plan declared for its price,
        # which stays right when the customer changes plan in the billing portal;
        # else the `plan` Belt::Pay.subscribe stamped on its metadata.
        def subscription_plan_key(subscription)
          items = value(value(subscription, :items), :data)
          price_id = reference_id(value(Array(items).first, :price))
          declared = Belt::Pay.plan_for_price(price_id)
          return declared.key.to_s if declared

          stamped = value(value(subscription, :metadata), :plan).to_s
          stamped.empty? ? nil : stamped
        end

        def find_customer(customer_id)
          model = Belt::Pay.configuration.customer_model
          unless model
            Belt::Pay.log(:error,
                          'Belt::Pay::WebhookHandler: customer_class is not configured, so pay_plan cannot ' \
                          'follow the subscription; set Belt::Pay.configuration.customer_class',
                          customer_id: customer_id)
            return nil
          end

          model.find(customer_id)
        rescue ActiveItem::RecordNotFound
          Belt::Pay.log(:warn, 'Belt::Pay::WebhookHandler: subscription for an unknown customer',
                        customer_id: customer_id)
          nil
        end

        # Money went back. The transaction keeps how much (`amount_refunded_cents`,
        # Stripe's running total for the charge) and becomes `refunded` once all of
        # it has; a part refund leaves it `completed`.
        def handle_charge_refunded(charge)
          transaction = transaction_for_payment(charge)
          return unless transaction

          transaction.amount_refunded_cents = value(charge, :amount_refunded)
          if value(charge, :refunded) == true && %w[completed disputed].include?(transaction.status)
            transaction.status = 'refunded'
            transaction.description = 'Refunded'
          end
          transaction.save!

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: charge refunded',
                        customer_id: transaction.customer_id, transaction_id: transaction.id,
                        amount_refunded_cents: transaction.amount_refunded_cents, status: transaction.status)
          transaction
        end

        # The buyer told their bank the payment wasn't theirs. The money is held by
        # Stripe from now until the dispute closes.
        def handle_dispute_created(dispute)
          transaction = transaction_for_payment(dispute)
          return unless transaction

          if transaction.status == 'completed'
            transaction.status = 'disputed'
            transaction.description = "Payment disputed (#{value(dispute, :id)})"
            transaction.save!
          end

          Belt::Pay.log(:warn, 'Belt::Pay::WebhookHandler: payment disputed',
                        customer_id: transaction.customer_id, transaction_id: transaction.id,
                        dispute_id: value(dispute, :id))
          transaction
        end

        # A dispute won (or an inquiry closed without a chargeback) gives the money
        # back to the seller: `completed` again. One lost is money gone: `refunded`.
        def handle_dispute_closed(dispute)
          transaction = transaction_for_payment(dispute)
          return unless transaction

          outcome = value(dispute, :status).to_s
          if outcome == 'lost' && %w[completed disputed].include?(transaction.status)
            # Also from completed: the dispute's opening event may never have arrived.
            transaction.status = 'refunded'
            transaction.description = "Dispute lost (#{value(dispute, :id)})"
            transaction.save!
          elsif %w[won warning_closed].include?(outcome) && transaction.status == 'disputed'
            transaction.status = 'completed'
            transaction.description = "Dispute #{outcome == 'won' ? 'won' : 'closed'} (#{value(dispute, :id)})"
            transaction.save!
          end

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: dispute closed',
                        customer_id: transaction.customer_id, transaction_id: transaction.id,
                        dispute_id: value(dispute, :id), outcome: outcome, status: transaction.status)
          transaction
        end

        # The transaction a charge or dispute belongs to. They name only the payment,
        # so a renewal is found by its invoice id and a checkout by asking Stripe
        # which Checkout Session the payment came from. Nil for a payment this app
        # has no transaction for; a Stripe error is raised so the event is retried.
        def transaction_for_payment(object)
          renewal = Transaction.lookup(reference_id(value(object, :invoice)))
          return renewal if renewal

          payment_intent_id = reference_id(value(object, :payment_intent))
          return nil unless payment_intent_id

          Transaction.for_session(Belt::Pay.provider.checkout_session_id_for(payment_intent_id))
        end

        def resolve_customer_from_subscription(subscription_id)
          return nil unless subscription_id

          Belt::Pay.provider.ensure_api_key!
          app_customer_id(::Stripe::Subscription.retrieve(subscription_id))
        rescue StandardError => e
          Belt::Pay.log(:warn, 'Belt::Pay::WebhookHandler: failed to resolve customer from subscription',
                        subscription_id: subscription_id, error: e.message)
          nil
        end

        # The invoice's subscription id. Stripe API versions from 2025-03-31 moved
        # it under parent.subscription_details.
        def invoice_subscription_id(invoice)
          direct = reference_id(value(invoice, :subscription))
          return direct if direct

          reference_id(value(value(value(invoice, :parent), :subscription_details), :subscription))
        end

        # The app's customer id, stamped on the object's metadata as app_customer_id.
        def app_customer_id(object)
          id = value(value(object, :metadata), :app_customer_id)
          id.to_s.empty? ? nil : id
        end

        # Read an attribute that may not be there. A Stripe object raises
        # NoMethodError for a field the event doesn't carry, and which fields it
        # carries depends on the endpoint's API version.
        def value(object, key)
          return nil if object.nil?
          return object.public_send(key) if object.respond_to?(key)
          return nil unless object.respond_to?(:[])

          object[key.to_s]
        end

        # A reference is an id, or the object itself when the field was expanded.
        def reference_id(reference)
          id = reference.is_a?(String) ? reference : value(reference, :id)
          id.to_s.empty? ? nil : id
        end
      end
    end
  end
end
