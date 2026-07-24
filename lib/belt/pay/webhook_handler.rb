# frozen_string_literal: true

module Belt
  module Pay
    # Handles incoming webhooks from the payment provider.
    # Verifies signatures, dispatches events, and records transactions.
    module WebhookHandler
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

        def dispatch(event)
          event_type = event['type'] || event.type

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: received event', event_type: event_type)

          case event_type
          when 'checkout.session.completed'
            handle_checkout_completed(event.data.object)
          when 'checkout.session.expired'
            handle_checkout_expired(event.data.object)
          when 'invoice.paid'
            handle_invoice_paid(event.data.object)
          when 'invoice.payment_failed'
            handle_invoice_payment_failed(event.data.object)
          when 'customer.subscription.deleted'
            handle_subscription_deleted(event.data.object)
          when 'customer.subscription.updated'
            handle_subscription_updated(event.data.object)
          else
            Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: unhandled event type', event_type: event_type)
          end
        end

        def handle_checkout_completed(session)
          customer_id = session.metadata&.app_customer_id || session.metadata&.[]('app_customer_id')
          return unless customer_id

          # Complete the pending transaction
          pending = Transaction.where(
            provider_session_id: session.id,
            index: 'ProviderSessionIndex'
          ).first

          if pending&.status == 'pending'
            pending.status = 'completed'
            pending.amount_cents = session.amount_total
            pending.save!
          else
            # No pending record — create one (webhook-first flow)
            Transaction.record_checkout(
              customer_id: customer_id,
              session_id: session.id,
              amount_cents: session.amount_total || 0,
              metadata: { payment_status: session.payment_status }
            )
          end

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: checkout completed',
                        customer_id: customer_id, session_id: session.id,
                        amount_cents: session.amount_total)
        end

        def handle_checkout_expired(session)
          # Mark pending transaction as failed
          pending = Transaction.where(
            provider_session_id: session.id,
            index: 'ProviderSessionIndex'
          ).first

          if pending&.status == 'pending'
            pending.status = 'failed'
            pending.description = 'Checkout session expired'
            pending.save!
          end

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: checkout expired', session_id: session.id)
        end

        def handle_invoice_paid(invoice)
          subscription_id = invoice.subscription
          customer_id = invoice.metadata&.app_customer_id || invoice.metadata&.[]('app_customer_id')

          # Try to resolve customer from subscription metadata if not on invoice
          unless customer_id
            customer_id = resolve_customer_from_subscription(subscription_id)
          end

          return unless customer_id && subscription_id

          Transaction.record_renewal(
            customer_id: customer_id,
            subscription_id: subscription_id,
            amount_cents: invoice.amount_paid || 0,
            metadata: { invoice_id: invoice.id, billing_reason: invoice.billing_reason }
          )

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: invoice paid',
                        customer_id: customer_id, subscription_id: subscription_id,
                        amount_cents: invoice.amount_paid)
        end

        def handle_invoice_payment_failed(invoice)
          customer_id = invoice.metadata&.app_customer_id || invoice.metadata&.[]('app_customer_id')
          unless customer_id
            customer_id = resolve_customer_from_subscription(invoice.subscription)
          end

          Belt::Pay.log(:warn, 'Belt::Pay::WebhookHandler: invoice payment failed',
                        customer_id: customer_id, invoice_id: invoice.id)
        end

        def handle_subscription_deleted(subscription)
          customer_id = subscription.metadata&.app_customer_id || subscription.metadata&.[]('app_customer_id')
          return unless customer_id

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: subscription deleted',
                        customer_id: customer_id, subscription_id: subscription.id)
        end

        def handle_subscription_updated(subscription)
          customer_id = subscription.metadata&.app_customer_id || subscription.metadata&.[]('app_customer_id')
          return unless customer_id

          Belt::Pay.log(:info, 'Belt::Pay::WebhookHandler: subscription updated',
                        customer_id: customer_id, subscription_id: subscription.id,
                        status: subscription.status)
        end

        def resolve_customer_from_subscription(subscription_id)
          return nil unless subscription_id

          Belt::Pay.provider.ensure_api_key!
          sub = ::Stripe::Subscription.retrieve(subscription_id)
          sub.metadata&.app_customer_id || sub.metadata&.[]('app_customer_id')
        rescue StandardError => e
          Belt::Pay.log(:warn, 'Belt::Pay::WebhookHandler: failed to resolve customer from subscription',
                        subscription_id: subscription_id, error: e.message)
          nil
        end
      end
    end
  end
end
