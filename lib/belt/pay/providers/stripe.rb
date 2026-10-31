# frozen_string_literal: true

require 'stripe'

module Belt
  module Pay
    module Providers
      # Stripe provider adapter.
      # Handles API key management and provides the Stripe-specific implementations
      # that the generic Belt::Pay API delegates to.
      class Stripe
        # Ensure the Stripe API key is set for the current request.
        # Reads from Secrets Manager via the configured secret name.
        def ensure_api_key!
          ::Stripe.api_key ||= fetch_api_key
          raise ConfigurationError, 'Stripe API key not configured' unless ::Stripe.api_key
        end

        # Get the webhook signing secret for signature verification.
        # @return [String]
        def webhook_signing_secret
          @webhook_signing_secret ||= fetch_webhook_secret
        end

        # Create a Stripe customer for the given user.
        # @param customer [Object] App model with #id, #email
        # @return [String] Stripe customer ID (cus_xxx)
        def create_customer(customer)
          ensure_api_key!
          stripe_customer = ::Stripe::Customer.create(
            email: customer.respond_to?(:email) ? customer.email : nil,
            metadata: { app_customer_id: customer.id }
          )
          stripe_customer.id
        end

        # Attach a payment method to a Stripe customer and set as default.
        # @param pay_customer_id [String] Stripe customer ID
        # @param payment_method_id [String] Payment method ID (pm_xxx)
        def attach_payment_method(pay_customer_id, payment_method_id)
          ensure_api_key!
          ::Stripe::PaymentMethod.attach(payment_method_id, { customer: pay_customer_id })
          ::Stripe::Customer.update(pay_customer_id, {
            invoice_settings: { default_payment_method: payment_method_id }
          })
        rescue ::Stripe::InvalidRequestError => e
          raise unless e.message.include?('already been attached')

          # Idempotent — already attached, just set as default
          ::Stripe::Customer.update(pay_customer_id, {
            invoice_settings: { default_payment_method: payment_method_id }
          })
        end

        # Create a SetupIntent for collecting payment details.
        # @param pay_customer_id [String] Stripe customer ID
        # @param customer_id [String] App customer ID (for metadata)
        # @return [Hash] { client_secret:, setup_intent_id: }
        def create_setup_intent(pay_customer_id, customer_id:)
          ensure_api_key!
          setup_intent = ::Stripe::SetupIntent.create({
            customer: pay_customer_id,
            payment_method_types: ['card'],
            usage: 'off_session',
            metadata: { app_customer_id: customer_id }
          })
          { client_secret: setup_intent.client_secret, setup_intent_id: setup_intent.id }
        end

        # Stripe Checkout Session options that #create_checkout_session forwards verbatim
        # when given. Anything else raises ArgumentError so a missing option fails loudly
        # instead of being silently dropped; pass `extra:` to send a key not listed here.
        # @see https://docs.stripe.com/api/checkout/sessions/create
        CHECKOUT_SESSION_OPTIONS = %i[
          subscription_data payment_intent_data setup_intent_data
          allow_promotion_codes discounts automatic_tax tax_id_collection
          customer_update customer_creation client_reference_id currency locale expires_at
          payment_method_types payment_method_collection payment_method_options
          payment_method_configuration saved_payment_method_options
          billing_address_collection shipping_address_collection shipping_options
          phone_number_collection consent_collection custom_fields custom_text submit_type
          invoice_creation after_expiration adaptive_pricing optional_items
          ui_mode return_url redirect_on_completion
        ].freeze

        # Create a Checkout Session.
        #
        # Every key in CHECKOUT_SESSION_OPTIONS (e.g. `allow_promotion_codes:`,
        # `automatic_tax:`, `payment_intent_data:`, `subscription_data:`) is forwarded to
        # Stripe as-is. Keys with a nil value are omitted. Unknown keys raise
        # ArgumentError; use `extra:` for a Stripe option this list doesn't know about yet.
        #
        # @param pay_customer_id [String] Stripe customer ID
        # @param line_items [Array<Hash>]
        # @param mode [String] 'payment', 'subscription' or 'setup' (default 'payment')
        # @param success_url [String, nil]
        # @param cancel_url [String, nil]
        # @param metadata [Hash]
        # @param extra [Hash] Additional Checkout Session params merged in last, unvalidated
        # @param options [Hash] Any key in CHECKOUT_SESSION_OPTIONS
        # @return [Hash] { url:, session_id: }
        # @raise [ArgumentError] when an option is not a known Checkout Session param
        def create_checkout_session(pay_customer_id, line_items:, mode: 'payment', success_url: nil,
                                    cancel_url: nil, metadata: {}, extra: {}, **options)
          ensure_api_key!
          params = {
            customer: pay_customer_id,
            line_items: line_items,
            mode: mode || 'payment',
            success_url: success_url,
            cancel_url: cancel_url,
            metadata: metadata || {}
          }
          params.merge!(checkout_session_options(options))
          params.merge!(extra) if extra

          session = ::Stripe::Checkout::Session.create(params.compact)
          { url: session.url, session_id: session.id }
        end

        # Create a subscription directly (without Checkout).
        # @param pay_customer_id [String] Stripe customer ID
        # @param price_id [String] Stripe price ID
        # @param metadata [Hash]
        # @return [Hash] { subscription_id:, status:, current_period_end: }
        def create_subscription(pay_customer_id, price_id:, metadata: {})
          ensure_api_key!
          subscription = ::Stripe::Subscription.create({
            customer: pay_customer_id,
            items: [{ price: price_id }],
            metadata: metadata,
            payment_behavior: 'default_incomplete',
            expand: ['latest_invoice.payment_intent']
          })
          {
            subscription_id: subscription.id,
            status: subscription.status,
            current_period_end: Time.at(subscription.current_period_end).utc.iso8601
          }
        end

        # Cancel a subscription.
        # @param subscription_id [String] Stripe subscription ID
        # @param immediately [Boolean] Cancel now or at period end
        def cancel_subscription(subscription_id, immediately: false)
          ensure_api_key!
          if immediately
            ::Stripe::Subscription.cancel(subscription_id)
          else
            ::Stripe::Subscription.update(subscription_id, { cancel_at_period_end: true })
          end
        end

        # Check if a subscription is active.
        # @param subscription_id [String] Stripe subscription ID
        # @return [Boolean]
        def subscription_active?(subscription_id)
          ensure_api_key!
          sub = ::Stripe::Subscription.retrieve(subscription_id)
          %w[active trialing].include?(sub.status)
        rescue ::Stripe::InvalidRequestError
          false
        end

        # Generate a billing portal session URL.
        # @param pay_customer_id [String] Stripe customer ID
        # @param return_url [String]
        # @return [Hash] { url: }
        def billing_portal(customer, return_url:)
          ensure_api_key!
          pay_customer_id = customer.pay_customer_id
          raise Error, 'Customer has no payment account' unless pay_customer_id

          session = ::Stripe::BillingPortal::Session.create({
            customer: pay_customer_id,
            return_url: return_url
          })
          { url: session.url }
        end

        # Get payment method details for a customer.
        # @param customer [Object] App model with #pay_customer_id
        # @return [Hash, nil] { last4:, brand:, exp_month:, exp_year: }
        def payment_method_details(customer)
          ensure_api_key!
          return nil unless customer.pay_customer_id

          stripe_customer = ::Stripe::Customer.retrieve(customer.pay_customer_id)
          default_pm_id = stripe_customer.invoice_settings&.default_payment_method
          return nil unless default_pm_id

          pm = ::Stripe::PaymentMethod.retrieve(default_pm_id)
          return nil unless pm&.card

          { last4: pm.card.last4, brand: pm.card.brand,
            exp_month: pm.card.exp_month, exp_year: pm.card.exp_year }
        rescue ::Stripe::InvalidRequestError
          nil
        end

        # Verify a webhook signature and parse the event.
        # @param payload [String] Raw request body
        # @param signature [String] Stripe-Signature header
        # @return [Stripe::Event]
        def verify_webhook(payload, signature)
          ::Stripe::Webhook.construct_event(payload, signature, webhook_signing_secret)
        end

        private

        # Validate and compact the pass-through Checkout Session options.
        def checkout_session_options(options)
          unknown = options.keys - CHECKOUT_SESSION_OPTIONS
          if unknown.any?
            raise ArgumentError,
                  "Unknown Checkout Session option(s): #{unknown.map(&:inspect).join(', ')}. " \
                  "Supported: #{CHECKOUT_SESSION_OPTIONS.join(', ')}. " \
                  'Pass `extra: { ... }` to forward a param not listed here.'
          end

          options.compact
        end

        def fetch_api_key
          secret_name = Belt::Pay.configuration.secret_name
          return nil unless secret_name

          require_secrets_helper
          SecretsHelper.get_secret(secret_name: secret_name, key: 'stripe_secret_key', required: true)
        rescue StandardError => e
          Belt::Pay.log(:error, 'Failed to fetch Stripe API key', error: e.message)
          nil
        end

        def fetch_webhook_secret
          secret_name = Belt::Pay.configuration.webhook_secret_name || Belt::Pay.configuration.secret_name
          return nil unless secret_name

          require_secrets_helper
          SecretsHelper.get_secret(secret_name: secret_name, key: 'stripe_webhook_secret', required: true)
        rescue StandardError => e
          Belt::Pay.log(:error, 'Failed to fetch Stripe webhook secret', error: e.message)
          nil
        end

        def require_secrets_helper
          require 'belt/secrets_helper' if defined?(Belt::SecretsHelper)
        rescue LoadError
          # SecretsHelper not available — key must be set via Stripe.api_key directly
        end
      end
    end
  end
end
