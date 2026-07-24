# frozen_string_literal: true

RSpec.describe Belt::Pay::Providers::Stripe do
  subject(:provider) { described_class.new }

  describe '#ensure_api_key!' do
    it 'raises ConfigurationError when no key is available' do
      allow(Stripe).to receive(:api_key).and_return(nil)
      allow(provider).to receive(:fetch_api_key).and_return(nil)
      expect { provider.ensure_api_key! }.to raise_error(Belt::Pay::ConfigurationError)
    end

    it 'succeeds when api_key is already set' do
      allow(Stripe).to receive(:api_key).and_return('sk_test_xxx')
      expect { provider.ensure_api_key! }.not_to raise_error
    end
  end

  describe '#create_customer' do
    let(:customer) { double(id: 'cust-123', email: 'test@example.com') }

    it 'creates a Stripe customer with email and metadata' do
      allow(Stripe).to receive(:api_key).and_return('sk_test_xxx')
      stripe_customer = double(id: 'cus_new_123')
      expect(Stripe::Customer).to receive(:create).with(
        email: 'test@example.com',
        metadata: { app_customer_id: 'cust-123' }
      ).and_return(stripe_customer)

      expect(provider.create_customer(customer)).to eq('cus_new_123')
    end
  end

  describe '#subscription_active?' do
    before { allow(Stripe).to receive(:api_key).and_return('sk_test_xxx') }

    it 'returns true for active subscription' do
      sub = double(status: 'active')
      allow(Stripe::Subscription).to receive(:retrieve).and_return(sub)
      expect(provider.subscription_active?('sub_123')).to be true
    end

    it 'returns true for trialing subscription' do
      sub = double(status: 'trialing')
      allow(Stripe::Subscription).to receive(:retrieve).and_return(sub)
      expect(provider.subscription_active?('sub_123')).to be true
    end

    it 'returns false for canceled subscription' do
      sub = double(status: 'canceled')
      allow(Stripe::Subscription).to receive(:retrieve).and_return(sub)
      expect(provider.subscription_active?('sub_123')).to be false
    end

    it 'returns false when subscription not found' do
      allow(Stripe::Subscription).to receive(:retrieve)
        .and_raise(Stripe::InvalidRequestError.new('not found', 'id'))
      expect(provider.subscription_active?('sub_invalid')).to be false
    end
  end
end
