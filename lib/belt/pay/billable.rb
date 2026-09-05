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
        attr_accessor :pay_customer_id, :pay_subscription_id, :pay_payment_method_id, :pay_plan
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
      #
      # Pass either a declared plan key (`plan:`) or a raw `price_id:`.
      # When a plan key is given, the customer's `pay_plan` is recorded so
      # limits/features can be checked later without a Stripe round-trip.
      #
      # @param plan [Symbol, String, nil] A declared plan key (see Belt::Pay.plans)
      # @param price_id [String, nil] Provider price ID (overrides plan lookup)
      # @param interval [Symbol] Billing interval to pick from the plan (default :month)
      # @param metadata [Hash] Additional metadata to store on the subscription
      # @return [Hash] { subscription_id:, status: }
      def subscribe!(plan: nil, price_id: nil, interval: :month, metadata: {})
        result = Belt::Pay.subscribe(self, plan: plan, price_id: price_id,
                                           interval: interval, metadata: metadata)
        self.pay_subscription_id = result[:subscription_id]
        self.pay_plan = plan.to_s if plan
        save(validate: false)
        result
      end

      # The declared plan this customer is currently on (or nil).
      # @return [Belt::Pay::Plan, nil]
      def plan
        Belt::Pay.plan(pay_plan) if pay_plan
      end

      # Is this customer on a given plan?
      # @param plan_key [Symbol, String]
      # @return [Boolean]
      def on_plan?(plan_key)
        pay_plan.to_s == plan_key.to_s
      end

      # Does this customer's plan allow a named feature?
      # @param feature_name [Symbol, String]
      # @return [Boolean]
      def plan_allows?(feature_name)
        p = plan
        return false unless p

        p.includes_feature?(feature_name)
      end

      # Is the given usage under this customer's plan limit for `limit_name`?
      # Returns true when there is no plan or the limit is unlimited/undeclared.
      # @param limit_name [Symbol, String]
      # @param usage [Integer] Current usage count
      # @return [Boolean]
      def within_limit?(limit_name, usage)
        p = plan
        return true unless p

        p.allows?(limit_name, usage)
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
