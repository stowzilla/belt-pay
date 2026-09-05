# frozen_string_literal: true

require_relative 'pay/version'
require_relative 'pay/configuration'
require_relative 'pay/plan_registry'
require_relative 'pay/transaction'
require_relative 'pay/billable'
require_relative 'pay/checkout'
require_relative 'pay/subscription'
require_relative 'pay/customer_provisioner'
require_relative 'pay/payment_method_attacher'
require_relative 'pay/setup_intent_creator'
require_relative 'pay/webhook_handler'
require_relative 'pay/providers/stripe'

module Belt
  module Pay
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class ProviderError < Error; end

    class << self
      attr_writer :configuration

      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end

      def reset_configuration!
        @configuration = Configuration.new
      end

      # --- Plans (convention-over-configuration subscription plan DSL) ---

      # The plan registry. Pass a block to declare plans, or call with no block
      # to read the registry.
      #
      # @example
      #   Belt::Pay.plans do
      #     plan(:pro) { name 'Pro'; price 49, stripe_price: 'price_xxx' }
      #   end
      #
      # @return [Belt::Pay::PlanRegistry]
      def plans(&block)
        @plans ||= PlanRegistry.new
        @plans.instance_eval(&block) if block
        @plans
      end

      # Look up a single plan by key. Returns nil if undeclared.
      # @return [Belt::Pay::Plan, nil]
      def plan(key)
        plans.find(key)
      end

      # Find the declared plan backing a given Stripe price ID.
      # @return [Belt::Pay::Plan, nil]
      def plan_for_price(price_id)
        plans.find_by_stripe_price(price_id)
      end

      # Reset the plan registry (useful for tests).
      def reset_plans!
        @plans = PlanRegistry.new
      end

      # --- Convenience API (provider-agnostic names) ---

      # Ensure a payment provider customer exists for this user.
      # @param customer [Object] Your app's user/customer model instance
      # @return [String] The provider customer ID
      def ensure_customer(customer)
        CustomerProvisioner.new(customer).call
      end

      # Attach a payment method and set as default.
      # @param customer [Object] Your app's user/customer model instance
      # @param payment_method_id [String] Provider payment method token
      # @return [PaymentMethodAttacher::Result]
      def attach_payment_method(customer, payment_method_id)
        PaymentMethodAttacher.new(customer, payment_method_id).call
      end

      # Create a setup intent for collecting payment details on the frontend.
      # @param customer [Object] Your app's user/customer model instance
      # @return [SetupIntentCreator::Result]
      def create_setup_intent(customer)
        SetupIntentCreator.new(customer).call
      end

      # Create a checkout session for one-time or subscription payments.
      # @param customer [Object] Your app's user/customer model instance
      # @param options [Hash] Checkout options (line_items, mode, success_url, cancel_url, metadata)
      # @return [Hash] { url:, session_id: }
      def create_checkout(customer, **options)
        Checkout.create(customer, **options)
      end

      # Subscribe a customer to a plan.
      #
      # Pass either a declared plan (`plan:`) — which resolves to the right Stripe
      # price for the interval — or a raw provider `price_id:`.
      #
      # @param customer [Object] Your app's user/customer model instance
      # @param plan [Symbol, String, nil] A declared plan key (see Belt::Pay.plans)
      # @param price_id [String, nil] Provider price/plan ID (overrides plan lookup)
      # @param interval [Symbol] Billing interval to pick from the plan (default :month)
      # @param metadata [Hash] Additional metadata
      # @return [Hash] { subscription_id:, status: }
      def subscribe(customer, plan: nil, price_id: nil, interval: :month, metadata: {})
        price_id ||= resolve_plan_price(plan, interval)
        meta = metadata.dup
        meta[:plan] ||= plan.to_s if plan
        Subscription.create(customer, price_id: price_id, metadata: meta)
      end

      # Cancel a customer's subscription.
      # @param customer [Object] Your app's user/customer model instance
      # @param immediately [Boolean] Cancel now vs at period end (default: false)
      def cancel_subscription(customer, immediately: false)
        Subscription.cancel(customer, immediately: immediately)
      end

      # Generate a billing portal URL for customer self-service.
      # @param customer [Object] Your app's user/customer model instance
      # @param return_url [String] URL to redirect back to after portal
      # @return [Hash] { url: }
      def billing_portal(customer, return_url:)
        provider.billing_portal(customer, return_url: return_url)
      end

      # Get the configured provider adapter instance.
      # @return [Belt::Pay::Providers::Stripe] (or future providers)
      def provider
        @provider ||= resolve_provider
      end

      # Reset provider (useful for testing)
      def reset_provider!
        @provider = nil
      end

      # Internal logging helper
      def log(level, message, **kwargs)
        if defined?(Belt::Observability::Logger)
          Belt::Observability::Logger.public_send(level, message, **kwargs)
        elsif configuration.logger
          configuration.logger.public_send(level, message, **kwargs)
        end
      end

      private

      # Resolve a plan key (+ interval) to its Stripe price ID.
      def resolve_plan_price(plan_key, interval)
        return nil if plan_key.nil?

        pl = plans.find!(plan_key)
        price_id = pl.stripe_price_id(interval: interval)
        raise ConfigurationError, "Plan #{plan_key.inspect} has no Stripe price for interval #{interval.inspect}" unless price_id

        price_id
      end

      def resolve_provider
        case configuration.provider
        when :stripe
          Providers::Stripe.new
        else
          raise ConfigurationError, "Unknown provider: #{configuration.provider}. Supported: :stripe"
        end
      end
    end
  end
end
