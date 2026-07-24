# frozen_string_literal: true

require 'active_support/concern'

module Belt
  module Pay
    # Mix into your Customer/User model to get payment capabilities.
    #
    # @example
    #   class Customer < ActiveItem::Base
    #     include Belt::Pay::Billable
    #   end
    #
    #   customer.ensure_pay_customer!
    #   customer.subscribe!(price_id: 'price_xxx')
    #   customer.active_subscription?
    #   customer.cancel_subscription!
    #   customer.transactions
    #
    module Billable
      extend ActiveSupport::Concern

      included do
        attr_accessor :pay_customer_id, :pay_subscription_id, :pay_payment_method_id
      end

      # Ensure this customer has a provider customer account.
      # Creates one if it doesn't exist. Idempotent.
      # @return [String] The provider customer ID
      def ensure_pay_customer!
        Belt::Pay.ensure_customer(self)
      end

      # Attach a payment method and set as default.
      # @param payment_method_id [String] Provider payment method token (e.g., 'pm_xxx')
      # @return [PaymentMethodAttacher::Result]
      def attach_payment_method(payment_method_id)
        Belt::Pay.attach_payment_method(self, payment_method_id)
      end

      # Create a setup intent for collecting payment details.
      # @return [SetupIntentCreator::Result] { client_secret:, pay_customer_id: }
      def create_setup_intent
        Belt::Pay.create_setup_intent(self)
      end

      # Subscribe to a plan.
      # @param price_id [String] Provider price ID
      # @param metadata [Hash] Additional metadata to store on the subscription
      # @return [Hash] { subscription_id:, status: }
      def subscribe!(price_id:, metadata: {})
        result = Belt::Pay.subscribe(self, price_id: price_id, metadata: metadata)
        self.pay_subscription_id = result[:subscription_id]
        save(validate: false)
        result
      end

      # Check if customer has an active subscription.
      # @return [Boolean]
      def active_subscription?
        return false unless pay_subscription_id

        Belt::Pay::Subscription.active?(self)
      end

      # Cancel the current subscription.
      # @param immediately [Boolean] Cancel now (true) or at period end (false, default)
      def cancel_subscription!(immediately: false)
        Belt::Pay.cancel_subscription(self, immediately: immediately)
        self.pay_subscription_id = nil if immediately
        save(validate: false) if immediately
      end

      # Generate a billing portal URL for self-service management.
      # @param return_url [String] URL to redirect back to
      # @return [Hash] { url: }
      def billing_portal_url(return_url:)
        Belt::Pay.billing_portal(self, return_url: return_url)
      end

      # Get payment method details (last4, brand, expiry).
      # @return [Hash, nil] { last4:, brand:, exp_month:, exp_year: }
      def payment_method_details
        Belt::Pay.provider.payment_method_details(self)
      end

      # Get all transactions for this customer.
      # @return [Array<Belt::Pay::Transaction>]
      def transactions
        Belt::Pay::Transaction.for_customer(id)
      end
    end
  end
end
