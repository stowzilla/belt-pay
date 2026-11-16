# frozen_string_literal: true

module Belt
  module Pay
    # Creates checkout sessions for one-time or subscription payments.
    module Checkout
      class << self
        # Create a checkout session.
        # @param customer [Object] App model
        # @param line_items [Array<Hash>] Items to charge for
        # @param mode [String] 'payment' or 'subscription'
        # @param success_url [String]
        # @param cancel_url [String]
        # @param metadata [Hash]
        # @param options [Hash] Any other Checkout Session option the provider supports
        #   (e.g. allow_promotion_codes:, automatic_tax:, payment_intent_data:,
        #   subscription_data:). Forwarded verbatim; unknown keys raise ArgumentError.
        # @return [Hash] { url:, session_id: }
        def create(customer, line_items:, mode: 'payment', success_url:, cancel_url:, metadata: {}, **options)
          # Ensure provider customer exists
          CustomerProvisioner.new(customer).call

          result = Belt::Pay.provider.create_checkout_session(
            customer.pay_customer_id,
            line_items: line_items,
            mode: mode,
            success_url: success_url,
            cancel_url: cancel_url,
            metadata: metadata.merge(app_customer_id: customer.id),
            **options
          )

          # Record pending transaction
          Transaction.create!(
            customer_id: customer.id,
            provider: Belt::Pay.configuration.provider.to_s,
            provider_session_id: result[:session_id],
            type: mode == 'subscription' ? 'subscription' : 'checkout',
            status: 'pending',
            currency: checkout_currency(line_items, options),
            description: "Checkout session created (#{mode})",
            metadata: metadata
          )

          Belt::Pay.log(:info, 'Belt::Pay::Checkout: session created',
                        customer_id: customer.id, session_id: result[:session_id], mode: mode)

          result
        end

        private

        # The currency the session will charge in, when the request says: the
        # session's `currency:` or the first line item's inline price. A session
        # sold by price id doesn't say, so the pending row has none and the webhook
        # fills it in from the paid session.
        def checkout_currency(line_items, options)
          first = Array(line_items).first
          price_data = first.is_a?(Hash) ? (first[:price_data] || first['price_data']) : nil
          inline = price_data.is_a?(Hash) ? (price_data[:currency] || price_data['currency']) : nil
          currency = options[:currency] || inline
          currency&.to_s&.downcase
        end
      end
    end
  end
end
