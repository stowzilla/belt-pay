# frozen_string_literal: true

module Belt
  module Pay
    module Controllers
      # Default webhook controller for Stripe events.
      # Lives in the gem — override by generating a controller into your app:
      #   belt g pay --controllers
      class WebhooksController < BeltController::Base
        skip_before_action :authenticate!, only: [:webhook]

        # POST /pay/webhooks
        def webhook
          payload = raw_body
          signature = headers['Stripe-Signature'] || headers['stripe-signature']

          unless signature
            return error_response('Missing Stripe-Signature header', 400)
          end

          result = Belt::Pay::WebhookHandler.process(payload: payload, signature: signature)
          success_response(result)
        rescue ::Stripe::SignatureVerificationError => e
          Belt::Pay.log(:warn, 'Belt::Pay webhook signature verification failed', error: e.message)
          error_response('Invalid signature', 400)
        rescue StandardError => e
          Belt::Pay.log(:error, 'Belt::Pay webhook processing error', error: e.message)
          error_response('Webhook processing error', 500)
        end

        private

        # Get the raw request body for signature verification.
        # Stripe requires the exact raw body — not parsed JSON.
        def raw_body
          event.dig('body') || ''
        end

        def headers
          event.dig('headers') || {}
        end
      end
    end
  end
end
