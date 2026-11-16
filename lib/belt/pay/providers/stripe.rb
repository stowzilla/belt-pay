# frozen_string_literal: true

require 'stripe'

module Belt
  module Pay
    module Providers
      # Stripe provider adapter.
      # Handles API key management and provides the Stripe-specific implementations
      # that the generic Belt::Pay API delegates to.
      class Stripe
        # A real webhook signing secret. Anything else is refused, above all the
        # whsec_PLACEHOLDER older generated Terraform seeded the secret with: it is
        # public, so anyone could sign an event with it.
        WEBHOOK_SECRET_FORMAT = /\Awhsec_(?!PLACEHOLDER\z).+\z/

        # The API key older generated Terraform seeded (sk_test_PLACEHOLDER).
        API_KEY_PLACEHOLDER = /_PLACEHOLDER\z/i

        # Ensure the Stripe API key is set for the current request.
        # Reads from Secrets Manager via the configured secret name.
        # @raise [ConfigurationError] when there is no key, or it is still the placeholder
        def ensure_api_key!
          key = ::Stripe.api_key
          fetched = blank?(key)
          key = fetch_api_key if fetched
          raise ConfigurationError, 'Stripe API key not configured' if blank?(key)

          if API_KEY_PLACEHOLDER.match?(key)
            raise ConfigurationError,
                  'Stripe API key is still the placeholder; run `belt pay:setup <env>` to store a real key'
          end

          ::Stripe.api_key = key if fetched
        end

        # Get the webhook signing secret for signature verification. Only a usable
        # secret is remembered, so a warm Lambda picks up the real one after
        # `belt pay:setup` replaces a missing or placeholder value.
        # @return [String, nil]
        def webhook_signing_secret
          return @webhook_signing_secret if @webhook_signing_secret

          secret = fetch_webhook_secret
          secret = secret.strip if secret.is_a?(String)
          @webhook_signing_secret = secret if usable_webhook_secret?(secret)
          secret
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

        # The subscription as Stripe holds it now.
        # @param subscription_id [String] Stripe subscription ID
        # @return [Stripe::Subscription]
        def retrieve_subscription(subscription_id)
          ensure_api_key!
          ::Stripe::Subscription.retrieve(subscription_id)
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
        # @raise [ConfigurationError] when the signing secret is missing, blank or the
        #   placeholder. Nothing is verified against a secret that isn't one.
        def verify_webhook(payload, signature)
          secret = webhook_signing_secret
          unless usable_webhook_secret?(secret)
            raise ConfigurationError,
                  'Stripe webhook signing secret is missing or still the placeholder; ' \
                  'run `belt pay:setup <env>` to store the endpoint\'s whsec_ secret'
          end

          ::Stripe::Webhook.construct_event(payload, signature, secret)
        end

        # The id of the Checkout Session a payment was made through, or nil when the
        # payment didn't come from Checkout. Refunds and disputes name only the payment.
        # Stripe errors are raised, so the webhook fails and Stripe sends the event again.
        # @param payment_intent_id [String]
        # @return [String, nil]
        def checkout_session_id_for(payment_intent_id)
          ensure_api_key!
          sessions = ::Stripe::Checkout::Session.list({ payment_intent: payment_intent_id, limit: 1 })
          sessions.data.first&.id
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
          read_secret(Belt::Pay.configuration.secret_name, 'stripe_secret_key')
        rescue StandardError => e
          Belt::Pay.log(:error, 'Failed to fetch Stripe API key', error: e.message)
          nil
        end

        def fetch_webhook_secret
          secret_name = Belt::Pay.configuration.webhook_secret_name || Belt::Pay.configuration.secret_name
          read_secret(secret_name, 'stripe_webhook_secret')
        rescue StandardError => e
          Belt::Pay.log(:error, 'Failed to fetch Stripe webhook secret', error: e.message)
          nil
        end

        # Read one key of the JSON secret `belt pay:setup` writes. An app-defined
        # ::SecretsHelper is used when there is one; otherwise Secrets Manager is read
        # directly. Nothing is cached here: callers keep a value once it is usable.
        def read_secret(secret_name, key)
          return nil if blank?(secret_name)
          if defined?(::SecretsHelper)
            return ::SecretsHelper.get_secret(secret_name: secret_name, key: key, required: true)
          end

          require 'aws-sdk-secretsmanager'
          require 'json'
          response = Aws::SecretsManager::Client.new.get_secret_value(secret_id: secret_name)
          JSON.parse(response.secret_string)[key]
        end

        def usable_webhook_secret?(secret)
          secret.is_a?(String) && WEBHOOK_SECRET_FORMAT.match?(secret)
        end

        def blank?(value)
          value.nil? || value.to_s.strip.empty?
        end
      end
    end
  end
end
