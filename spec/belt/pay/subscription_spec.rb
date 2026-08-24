# frozen_string_literal: true

RSpec.describe Belt::Pay::Subscription do
  let(:provider) { instance_double(Belt::Pay::Providers::Stripe) }
  let(:customer) do
    double(
      id: 'cust-123',
      email: 'test@example.com',
      pay_customer_id: 'cus_stripe_123',
      pay_subscription_id: 'sub_existing',
      save: true
    )
  end
  let(:provisioner) { instance_double(Belt::Pay::CustomerProvisioner, call: 'cus_stripe_123') }

  before do
    allow(Belt::Pay).to receive(:provider).and_return(provider)
    allow(Belt::Pay).to receive(:log)
    allow(Belt::Pay::CustomerProvisioner).to receive(:new).and_return(provisioner)
  end

  describe '.create' do
    let(:subscription_result) do
      { subscription_id: 'sub_new_789', status: 'active', current_period_end: '2027-08-24T00:00:00Z' }
    end

    before do
      allow(provider).to receive(:create_subscription).and_return(subscription_result)
      allow(Belt::Pay::Transaction).to receive(:record_subscription)
    end

    it 'provisions the customer first' do
      expect(Belt::Pay::CustomerProvisioner).to receive(:new).with(customer).and_return(provisioner)
      expect(provisioner).to receive(:call)

      described_class.create(customer, price_id: 'price_xxx')
    end

    it 'creates a subscription via the provider' do
      expect(provider).to receive(:create_subscription).with(
        'cus_stripe_123',
        price_id: 'price_xxx',
        metadata: { app_customer_id: 'cust-123', plan: 'pro' }
      ).and_return(subscription_result)

      described_class.create(customer, price_id: 'price_xxx', metadata: { plan: 'pro' })
    end

    it 'records a subscription transaction' do
      expect(Belt::Pay::Transaction).to receive(:record_subscription).with(
        customer_id: 'cust-123',
        subscription_id: 'sub_new_789',
        amount_cents: 0,
        metadata: { plan: 'pro', price_id: 'price_xxx' }
      )

      described_class.create(customer, price_id: 'price_xxx', metadata: { plan: 'pro' })
    end

    it 'returns the subscription result' do
      result = described_class.create(customer, price_id: 'price_xxx')
      expect(result).to eq(subscription_result)
    end

    it 'logs the creation' do
      expect(Belt::Pay).to receive(:log).with(:info, 'Belt::Pay::Subscription: created',
                                              hash_including(customer_id: 'cust-123', subscription_id: 'sub_new_789'))
      described_class.create(customer, price_id: 'price_xxx')
    end
  end

  describe '.cancel' do
    it 'cancels the subscription via the provider' do
      expect(provider).to receive(:cancel_subscription).with('sub_existing', immediately: false)
      described_class.cancel(customer)
    end

    it 'passes immediately flag to provider' do
      expect(provider).to receive(:cancel_subscription).with('sub_existing', immediately: true)
      described_class.cancel(customer, immediately: true)
    end

    it 'logs the cancellation' do
      allow(provider).to receive(:cancel_subscription)
      expect(Belt::Pay).to receive(:log).with(:info, 'Belt::Pay::Subscription: canceled',
                                              hash_including(customer_id: 'cust-123', immediately: false))
      described_class.cancel(customer)
    end

    context 'when customer has no subscription' do
      let(:customer) { double(id: 'cust-123', pay_subscription_id: nil) }

      it 'raises an error' do
        expect { described_class.cancel(customer) }.to raise_error(
          Belt::Pay::Error, 'Customer has no active subscription'
        )
      end
    end
  end

  describe '.active?' do
    context 'when customer has a subscription' do
      it 'delegates to provider' do
        expect(provider).to receive(:subscription_active?).with('sub_existing').and_return(true)
        expect(described_class.active?(customer)).to be true
      end

      it 'returns false when provider says inactive' do
        expect(provider).to receive(:subscription_active?).with('sub_existing').and_return(false)
        expect(described_class.active?(customer)).to be false
      end
    end

    context 'when customer has no subscription' do
      let(:customer) { double(id: 'cust-123', pay_subscription_id: nil) }

      it 'returns false without calling provider' do
        expect(provider).not_to receive(:subscription_active?)
        expect(described_class.active?(customer)).to be false
      end
    end
  end
end
