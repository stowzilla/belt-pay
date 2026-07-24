# frozen_string_literal: true

require_relative 'pay/version'
require_relative 'pay/configuration'
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
      # @param customer [Object] Your app's user/customer model instance
      # @param price_id [String] Provider price/plan ID
      # @param metadata [Hash] Additional metadata
      # @return [Hash] { subscription_id:, status: }
      def subscribe(customer, price_id:, metadata: {})
        Subscription.create(customer, price_id: price_id, metadata: metadata)
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
