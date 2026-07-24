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
                    :type, :status, :amount_cents, :currency, :description,
                    :metadata, :created_at, :updated_at

      validates :customer_id, presence: true
      validates :type, presence: true
      validates :status, presence: true

      before_create { self.id ||= SecureRandom.uuid }
      before_create { self.created_at ||= Time.now.utc.iso8601 }
      before_save { self.updated_at = Time.now.utc.iso8601 }

      # Transaction types
      TYPES = %w[checkout subscription subscription_renewal refund payment_method_update].freeze

      # Transaction statuses
      STATUSES = %w[pending completed failed refunded canceled].freeze

      class << self
        # Record a checkout completion
        def record_checkout(customer_id:, session_id:, amount_cents:, currency: 'usd', metadata: {})
          create!(
            customer_id: customer_id,
            provider: Belt::Pay.configuration.provider.to_s,
            provider_session_id: session_id,
            type: 'checkout',
            status: 'completed',
            amount_cents: amount_cents,
            currency: currency,
            description: 'Checkout session completed',
            metadata: metadata
          )
        end

        # Record a subscription creation
        def record_subscription(customer_id:, subscription_id:, amount_cents:, currency: 'usd', metadata: {})
          create!(
            customer_id: customer_id,
            provider: Belt::Pay.configuration.provider.to_s,
            provider_subscription_id: subscription_id,
            type: 'subscription',
            status: 'completed',
            amount_cents: amount_cents,
            currency: currency,
            description: 'Subscription created',
            metadata: metadata
          )
        end

        # Record a subscription renewal (invoice paid)
        def record_renewal(customer_id:, subscription_id:, amount_cents:, currency: 'usd', metadata: {})
          create!(
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
      end
    end
  end
end
