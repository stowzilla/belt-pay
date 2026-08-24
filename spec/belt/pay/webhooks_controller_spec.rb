# frozen_string_literal: true

# Stub BeltController::Base for testing the webhooks controller in isolation.
# The real base class lives in the belt framework gem.
module BeltController
  class Base
    def self.skip_before_action(*); end

    def initialize(event: {})
      @event = event
    end

    def event
      @event
    end

    def success_response(data)
      { statusCode: 200, body: data }
    end

    def error_response(message, status)
      { statusCode: status, body: { error: message } }
    end

    private

    def raw_body
      event.dig('body') || ''
    end

    def headers
      event.dig('headers') || {}
    end
  end
end

require_relative '../../../lib/belt/pay/controllers/webhooks_controller'

RSpec.describe Belt::Pay::Controllers::WebhooksController do
  let(:controller) { described_class.new(event: event_data) }

  before do
    allow(Belt::Pay).to receive(:log)
  end

  describe '#webhook' do
    context 'when Stripe-Signature header is missing' do
      let(:event_data) do
        { 'body' => '{"id":"evt_123"}', 'headers' => {} }
      end

      it 'returns 400 with missing signature message' do
        result = controller.webhook
        expect(result[:statusCode]).to eq(400)
        expect(result[:body][:error]).to eq('Missing Stripe-Signature header')
      end
    end

    context 'when signature verification fails' do
      let(:event_data) do
        { 'body' => '{"id":"evt_123"}', 'headers' => { 'Stripe-Signature' => 'bad_sig' } }
      end

      it 'returns 400 with invalid signature message' do
        allow(Belt::Pay::WebhookHandler).to receive(:process)
          .and_raise(::Stripe::SignatureVerificationError.new('invalid', 'sig_header'))

        result = controller.webhook
        expect(result[:statusCode]).to eq(400)
        expect(result[:body][:error]).to eq('Invalid signature')
      end

      it 'logs the verification failure' do
        allow(Belt::Pay::WebhookHandler).to receive(:process)
          .and_raise(::Stripe::SignatureVerificationError.new('invalid sig', 'sig_header'))

        expect(Belt::Pay).to receive(:log).with(
          :warn,
          'Belt::Pay webhook signature verification failed',
          hash_including(:error)
        )

        controller.webhook
      end
    end

    context 'when a general error occurs during processing' do
      let(:event_data) do
        { 'body' => '{"id":"evt_123"}', 'headers' => { 'Stripe-Signature' => 't=123,v1=abc' } }
      end

      it 'returns 500 with webhook processing error message' do
        allow(Belt::Pay::WebhookHandler).to receive(:process)
          .and_raise(StandardError.new('something broke'))

        result = controller.webhook
        expect(result[:statusCode]).to eq(500)
        expect(result[:body][:error]).to eq('Webhook processing error')
      end

      it 'logs the processing error' do
        allow(Belt::Pay::WebhookHandler).to receive(:process)
          .and_raise(StandardError.new('something broke'))

        expect(Belt::Pay).to receive(:log).with(
          :error,
          'Belt::Pay webhook processing error',
          hash_including(error: 'something broke')
        )

        controller.webhook
      end
    end

    context 'when processing succeeds' do
      let(:event_data) do
        { 'body' => '{"id":"evt_123"}', 'headers' => { 'Stripe-Signature' => 't=123,v1=abc' } }
      end

      it 'returns 200 with success result' do
        allow(Belt::Pay::WebhookHandler).to receive(:process)
          .with(payload: '{"id":"evt_123"}', signature: 't=123,v1=abc')
          .and_return({ received: true })

        result = controller.webhook
        expect(result[:statusCode]).to eq(200)
        expect(result[:body]).to eq({ received: true })
      end
    end

    context 'when using lowercase stripe-signature header' do
      let(:event_data) do
        { 'body' => '{"id":"evt_123"}', 'headers' => { 'stripe-signature' => 't=123,v1=abc' } }
      end

      it 'accepts lowercase header name' do
        allow(Belt::Pay::WebhookHandler).to receive(:process)
          .and_return({ received: true })

        result = controller.webhook
        expect(result[:statusCode]).to eq(200)
      end
    end
  end
end
