# frozen_string_literal: true

require 'activeitem'
require 'securerandom'

module Belt
  module Pay
    # Internal Transaction model — lives in the gem, not generated into apps.
    # Records all payment events (checkouts, subscriptions, refunds) for audit logging.
    #
    # Override by creating your own Belt::Pay::Transaction class before requiring belt-pay,
    # or monkey-patch individual methods as needed.
    class Transaction < ActiveItem::Base
      self.table_name = -> { Belt::Pay.configuration.transactions_table_name }
      self.primary_key = :id

      attr_accessor :id, :customer_id, :provider, :provider_customer_id,
                    :provider_session_id, :provider_subscription_id, :provider_payment_intent_id,
                    :type, :status, :amount_cents, :amount_refunded_cents, :currency, :description,
                    :metadata, :created_at, :updated_at

      validates :customer_id, presence: true
      validates :type, presence: true
      validates :status, presence: true

      before_create { self.id ||= SecureRandom.uuid }
      before_create { self.created_at ||= Time.now.utc.iso8601 }
      before_save { self.updated_at = Time.now.utc.iso8601 }

      # Transaction types
      TYPES = %w[checkout subscription subscription_renewal refund payment_method_update].freeze

      # Transaction statuses. Only `completed` means the money is in: `pending` has
      # not been paid (yet), `refunded` and `disputed` mean it went back or may.
      STATUSES = %w[pending completed failed refunded disputed canceled].freeze

      class << self
        # Record a checkout seen first by the webhook (no pending row). The row's id
        # is the session id, so a second delivery of the event cannot add another.
        # @return [Transaction, nil] nil when the session is already recorded
        def record_checkout(customer_id:, session_id:, amount_cents:, currency: 'usd', status: 'completed',
                            payment_intent_id: nil, metadata: {})
          create_once!(
            id: session_id,
            customer_id: customer_id,
            provider: Belt::Pay.configuration.provider.to_s,
            provider_session_id: session_id,
            provider_payment_intent_id: payment_intent_id,
            type: 'checkout',
            status: status,
            amount_cents: amount_cents,
            currency: currency,
            description: status == 'completed' ? 'Checkout session completed' : 'Checkout session awaiting payment',
            metadata: metadata
          )
        end

        # Record a subscription creation. `completed` only once the subscription is
        # active; one that still needs its first payment is `pending`. The row's id is
        # the subscription id, so the webhook can find it.
        # @return [Transaction, nil] nil when the subscription is already recorded
        def record_subscription(customer_id:, subscription_id:, amount_cents:, currency: 'usd', status: 'completed',
                                metadata: {})
          create_once!(
            id: subscription_id,
            customer_id: customer_id,
            provider: Belt::Pay.configuration.provider.to_s,
            provider_subscription_id: subscription_id,
            type: 'subscription',
            status: status,
            amount_cents: amount_cents,
            currency: currency,
            description: 'Subscription created',
            metadata: metadata
          )
        end

        # Record a subscription renewal (invoice paid). Pass the invoice id as `id`
        # so a second delivery of the same invoice cannot add another row.
        # @return [Transaction, nil] nil when the invoice is already recorded
        def record_renewal(customer_id:, subscription_id:, amount_cents:, currency: 'usd', id: nil, metadata: {})
          create_once!(
            id: id,
            customer_id: customer_id,
            provider: Belt::Pay.configuration.provider.to_s,
            provider_subscription_id: subscription_id,
            type: 'subscription_renewal',
            status: 'completed',
            amount_cents: amount_cents,
            currency: currency,
            description: 'Subscription renewal',
            metadata: metadata
          )
        end

        # Record a refund
        def record_refund(customer_id:, amount_cents:, currency: 'usd', metadata: {})
          create!(
            customer_id: customer_id,
            provider: Belt::Pay.configuration.provider.to_s,
            type: 'refund',
            status: 'completed',
            amount_cents: amount_cents,
            currency: currency,
            description: 'Refund issued',
            metadata: metadata
          )
        end

        # Find transactions for a customer
        def for_customer(customer_id)
          where(customer_id: customer_id, index: 'CustomerIndex')
        end

        # The transaction of a Checkout Session: the pending row Checkout.create
        # wrote, or one the webhook recorded under the session id.
        # @return [Transaction, nil]
        def for_session(session_id)
          return nil if session_id.to_s.empty?

          where(provider_session_id: session_id, index: 'ProviderSessionIndex').first || lookup(session_id)
        end

        # Find by primary key; nil when there is no such row.
        # @return [Transaction, nil]
        def lookup(id)
          return nil if id.to_s.empty?

          find(id)
        rescue ActiveItem::RecordNotFound
          nil
        end

        # Create a row unless one with the same id exists (a conditional put), which
        # is what makes a redelivered webhook event harmless.
        # @return [Transaction, nil] nil when a row with that id already exists
        def create_once!(attributes)
          create!(attributes.compact)
        rescue ActiveItem::RecordInvalid => e
          raise unless e.record && e.record.errors[:id].include?('already exists')

          nil
        end
      end
    end
  end
end
