# frozen_string_literal: true

RSpec.describe Belt::Pay::WebhookHandler do
  let(:provider) { instance_double(Belt::Pay::Providers::Stripe) }

  before do
    allow(Belt::Pay).to receive(:provider).and_return(provider)
    allow(Belt::Pay).to receive(:log)
  end

  # Stripe events use both event['type'] and event.type access patterns.
  # Build event doubles that support both.
  def build_event(type:, object:)
    event = double('Event', type: type, data: double(object: object))
    allow(event).to receive(:[]).with('type').and_return(type)
    event
  end

  describe '.process' do
    let(:payload) { '{"id":"evt_123"}' }
    let(:signature) { 'whsec_sig_xxx' }
    let(:session) do
      double('Session',
             id: 'cs_123',
             metadata: double(app_customer_id: 'cust-1', :[] => 'cust-1'),
             amount_total: 9900,
             payment_status: 'paid')
    end
    let(:event) { build_event(type: 'checkout.session.completed', object: session) }

    it 'verifies the webhook signature via the provider' do
      allow(Belt::Pay::Transaction).to receive(:where).and_return([])
      allow(Belt::Pay::Transaction).to receive(:record_checkout)
      expect(provider).to receive(:verify_webhook).with(payload, signature).and_return(event)
      described_class.process(payload: payload, signature: signature)
    end

    it 'returns { received: true } on success' do
      allow(provider).to receive(:verify_webhook).and_return(event)
      allow(Belt::Pay::Transaction).to receive(:where).and_return([])
      allow(Belt::Pay::Transaction).to receive(:record_checkout)
      expect(described_class.process(payload: payload, signature: signature)).to eq({ received: true })
    end

    it 'raises when signature verification fails' do
      allow(provider).to receive(:verify_webhook)
        .and_raise(Stripe::SignatureVerificationError.new('invalid signature', 'sig_header'))
      expect { described_class.process(payload: payload, signature: signature) }
        .to raise_error(Stripe::SignatureVerificationError)
    end
  end

  describe 'checkout.session.completed' do
    let(:session) do
      double('Session',
             id: 'cs_123',
             metadata: double(app_customer_id: 'cust-1', :[] => 'cust-1'),
             amount_total: 4999,
             payment_status: 'paid')
    end
    let(:event) { build_event(type: 'checkout.session.completed', object: session) }

    context 'when a pending transaction exists' do
      let(:pending_txn) { double('Transaction', status: 'pending') }

      before do
        allow(provider).to receive(:verify_webhook).and_return(event)
        allow(Belt::Pay::Transaction).to receive(:where).and_return([pending_txn])
      end

      it 'marks the pending transaction as completed' do
        expect(pending_txn).to receive(:status=).with('completed')
        expect(pending_txn).to receive(:amount_cents=).with(4999)
        expect(pending_txn).to receive(:save!)
        described_class.process(payload: '{}', signature: 'sig')
      end
    end

    context 'when no pending transaction exists (webhook-first flow)' do
      before do
        allow(provider).to receive(:verify_webhook).and_return(event)
        allow(Belt::Pay::Transaction).to receive(:where).and_return([])
      end

      it 'creates a completed checkout transaction' do
        expect(Belt::Pay::Transaction).to receive(:record_checkout).with(
          customer_id: 'cust-1',
          session_id: 'cs_123',
          amount_cents: 4999,
          metadata: { payment_status: 'paid' }
        )
        described_class.process(payload: '{}', signature: 'sig')
      end
    end

    context 'when customer_id is nil' do
      let(:session_no_customer) do
        double('Session',
               id: 'cs_456',
               metadata: double(app_customer_id: nil, :[] => nil),
               amount_total: 1000)
      end
      let(:event) { build_event(type: 'checkout.session.completed', object: session_no_customer) }

      before do
        allow(provider).to receive(:verify_webhook).and_return(event)
      end

      it 'does not record a transaction' do
        expect(Belt::Pay::Transaction).not_to receive(:record_checkout)
        described_class.process(payload: '{}', signature: 'sig')
      end
    end
  end

  describe 'checkout.session.expired' do
    let(:session) { double('Session', id: 'cs_expired') }
    let(:event) { build_event(type: 'checkout.session.expired', object: session) }

    before { allow(provider).to receive(:verify_webhook).and_return(event) }

    context 'when a pending transaction exists' do
      let(:pending_txn) { double('Transaction', status: 'pending') }

      before do
        allow(Belt::Pay::Transaction).to receive(:where).and_return([pending_txn])
      end

      it 'marks the transaction as failed' do
        expect(pending_txn).to receive(:status=).with('failed')
        expect(pending_txn).to receive(:description=).with('Checkout session expired')
        expect(pending_txn).to receive(:save!)
        described_class.process(payload: '{}', signature: 'sig')
      end
    end

    context 'when no pending transaction exists' do
      before do
        allow(Belt::Pay::Transaction).to receive(:where).and_return([nil])
      end

      it 'does nothing' do
        expect { described_class.process(payload: '{}', signature: 'sig') }.not_to raise_error
      end
    end
  end

  describe 'invoice.paid' do
    let(:invoice) do
      double('Invoice',
             id: 'in_123',
             subscription: 'sub_456',
             metadata: double(app_customer_id: 'cust-1', :[] => 'cust-1'),
             amount_paid: 9900,
             billing_reason: 'subscription_cycle')
    end
    let(:event) { build_event(type: 'invoice.paid', object: invoice) }

    before { allow(provider).to receive(:verify_webhook).and_return(event) }

    it 'records a subscription renewal transaction' do
      expect(Belt::Pay::Transaction).to receive(:record_renewal).with(
        customer_id: 'cust-1',
        subscription_id: 'sub_456',
        amount_cents: 9900,
        metadata: { invoice_id: 'in_123', billing_reason: 'subscription_cycle' }
      )
      described_class.process(payload: '{}', signature: 'sig')
    end

    context 'when customer_id is not on invoice metadata' do
      let(:invoice_no_meta) do
        double('Invoice',
               id: 'in_789',
               subscription: 'sub_456',
               metadata: double(app_customer_id: nil, :[] => nil),
               amount_paid: 5000,
               billing_reason: 'subscription_create')
      end
      let(:event) { build_event(type: 'invoice.paid', object: invoice_no_meta) }
      let(:sub) { double('Subscription', metadata: double(app_customer_id: 'cust-2', :[] => 'cust-2')) }

      it 'resolves customer_id from the subscription' do
        allow(provider).to receive(:ensure_api_key!)
        allow(Stripe::Subscription).to receive(:retrieve).with('sub_456').and_return(sub)
        expect(Belt::Pay::Transaction).to receive(:record_renewal).with(
          customer_id: 'cust-2',
          subscription_id: 'sub_456',
          amount_cents: 5000,
          metadata: { invoice_id: 'in_789', billing_reason: 'subscription_create' }
        )
        described_class.process(payload: '{}', signature: 'sig')
      end
    end

    context 'when neither invoice nor subscription has customer_id' do
      let(:invoice_no_customer) do
        double('Invoice',
               id: 'in_000',
               subscription: nil,
               metadata: double(app_customer_id: nil, :[] => nil),
               amount_paid: 1000,
               billing_reason: 'manual')
      end
      let(:event) { build_event(type: 'invoice.paid', object: invoice_no_customer) }

      it 'does not record a transaction' do
        expect(Belt::Pay::Transaction).not_to receive(:record_renewal)
        described_class.process(payload: '{}', signature: 'sig')
      end
    end
  end

  describe 'invoice.payment_failed' do
    let(:invoice) do
      double('Invoice',
             id: 'in_fail_123',
             subscription: 'sub_456',
             metadata: double(app_customer_id: 'cust-1', :[] => 'cust-1'))
    end
    let(:event) { build_event(type: 'invoice.payment_failed', object: invoice) }

    before { allow(provider).to receive(:verify_webhook).and_return(event) }

    it 'logs a warning' do
      expect(Belt::Pay).to receive(:log).with(:info, anything, hash_including(event_type: 'invoice.payment_failed'))
      expect(Belt::Pay).to receive(:log).with(:warn, 'Belt::Pay::WebhookHandler: invoice payment failed',
                                              customer_id: 'cust-1', invoice_id: 'in_fail_123')
      described_class.process(payload: '{}', signature: 'sig')
    end
  end

  describe 'customer.subscription.deleted' do
    let(:subscription) do
      double('Subscription',
             id: 'sub_del_123',
             metadata: double(app_customer_id: 'cust-1', :[] => 'cust-1'))
    end
    let(:event) { build_event(type: 'customer.subscription.deleted', object: subscription) }

    before { allow(provider).to receive(:verify_webhook).and_return(event) }

    it 'logs the deletion' do
      expect(Belt::Pay).to receive(:log).with(:info, anything, hash_including(event_type: 'customer.subscription.deleted'))
      expect(Belt::Pay).to receive(:log).with(:info, 'Belt::Pay::WebhookHandler: subscription deleted',
                                              customer_id: 'cust-1', subscription_id: 'sub_del_123')
      described_class.process(payload: '{}', signature: 'sig')
    end
  end

  describe 'customer.subscription.updated' do
    let(:subscription) do
      double('Subscription',
             id: 'sub_upd_123',
             status: 'past_due',
             metadata: double(app_customer_id: 'cust-1', :[] => 'cust-1'))
    end
    let(:event) { build_event(type: 'customer.subscription.updated', object: subscription) }

    before { allow(provider).to receive(:verify_webhook).and_return(event) }

    it 'logs the update with status' do
      expect(Belt::Pay).to receive(:log).with(:info, anything, hash_including(event_type: 'customer.subscription.updated'))
      expect(Belt::Pay).to receive(:log).with(:info, 'Belt::Pay::WebhookHandler: subscription updated',
                                              customer_id: 'cust-1', subscription_id: 'sub_upd_123',
                                              status: 'past_due')
      described_class.process(payload: '{}', signature: 'sig')
    end
  end

  describe 'unhandled event type' do
    let(:event) { build_event(type: 'some.unknown.event', object: double) }

    before { allow(provider).to receive(:verify_webhook).and_return(event) }

    it 'logs info and does not raise' do
      expect(Belt::Pay).to receive(:log).with(:info, 'Belt::Pay::WebhookHandler: received event', event_type: 'some.unknown.event')
      expect(Belt::Pay).to receive(:log).with(:info, 'Belt::Pay::WebhookHandler: unhandled event type', event_type: 'some.unknown.event')
      expect { described_class.process(payload: '{}', signature: 'sig') }.not_to raise_error
    end
  end
end
