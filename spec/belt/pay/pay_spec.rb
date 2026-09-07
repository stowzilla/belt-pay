# frozen_string_literal: true

RSpec.describe Belt::Pay do
  describe '.configuration' do
    it 'returns a Configuration instance' do
      expect(described_class.configuration).to be_a(Belt::Pay::Configuration)
    end
  end

  describe '.configure' do
    it 'yields the configuration' do
      described_class.configure do |config|
        config.provider = :stripe
        config.table_name_prefix = 'test-app-dev'
      end

      expect(described_class.configuration.provider).to eq(:stripe)
      expect(described_class.configuration.table_name_prefix).to eq('test-app-dev')
    end
  end

  describe '.provider' do
    it 'returns Stripe provider by default' do
      expect(described_class.provider).to be_a(Belt::Pay::Providers::Stripe)
    end

    it 'raises for unknown provider' do
      described_class.configure { |c| c.provider = :paypal }
      expect { described_class.provider }.to raise_error(Belt::Pay::ConfigurationError, /Unknown provider/)
    end
  end

  describe '.reset_configuration!' do
    it 'resets to defaults' do
      described_class.configure { |c| c.provider = :stripe }
      described_class.reset_configuration!
      expect(described_class.configuration.provider).to eq(:stripe)
    end
  end

  describe '.subscribe (plan price resolution)' do
    let(:customer) { double('Customer', id: 'cust-1', pay_customer_id: 'cus_1') }
    let(:result) { { subscription_id: 'sub_1', status: 'active' } }

    before do
      described_class.plans do
        plan(:free) { name 'Free'; limit :projects, 1 }
        plan(:pro) do
          name 'Pro'
          price 49,  interval: :month, stripe_price: 'price_pro_month'
          price 490, interval: :year,  stripe_price: 'price_pro_year'
        end
      end
    end

    it 'resolves a plan key + interval to the Stripe price id' do
      expect(Belt::Pay::Subscription).to receive(:create).with(
        customer, price_id: 'price_pro_year', metadata: { plan: 'pro' }
      ).and_return(result)

      expect(described_class.subscribe(customer, plan: :pro, interval: :year)).to eq(result)
    end

    it 'defaults to the :month interval when none is given' do
      expect(Belt::Pay::Subscription).to receive(:create).with(
        customer, price_id: 'price_pro_month', metadata: { plan: 'pro' }
      ).and_return(result)

      described_class.subscribe(customer, plan: :pro)
    end

    it 'injects the plan key into metadata under :plan' do
      expect(Belt::Pay::Subscription).to receive(:create) do |_c, price_id:, metadata:|
        expect(metadata[:plan]).to eq('pro')
        result
      end

      described_class.subscribe(customer, plan: :pro)
    end

    it 'does not clobber a caller-supplied :plan metadata value' do
      expect(Belt::Pay::Subscription).to receive(:create) do |_c, price_id:, metadata:|
        expect(metadata[:plan]).to eq('legacy')
        result
      end

      described_class.subscribe(customer, plan: :pro, metadata: { plan: 'legacy' })
    end

    it 'does not mutate the caller-supplied metadata hash' do
      original = { source: 'web' }
      allow(Belt::Pay::Subscription).to receive(:create).and_return(result)

      described_class.subscribe(customer, plan: :pro, metadata: original)
      expect(original).to eq({ source: 'web' })
    end

    it 'prefers an explicit price_id over the plan lookup' do
      expect(Belt::Pay::Subscription).to receive(:create).with(
        customer, price_id: 'price_override', metadata: { plan: 'pro' }
      ).and_return(result)

      described_class.subscribe(customer, plan: :pro, price_id: 'price_override')
    end

    it 'works with a raw price_id and no plan (no :plan metadata added)' do
      expect(Belt::Pay::Subscription).to receive(:create).with(
        customer, price_id: 'price_raw', metadata: {}
      ).and_return(result)

      described_class.subscribe(customer, price_id: 'price_raw')
    end

    it 'raises when the plan key is unknown' do
      expect do
        described_class.subscribe(customer, plan: :enterprise)
      end.to raise_error(Belt::Pay::Error, /Unknown plan/)
    end

    it 'raises a ConfigurationError when the plan has no price for the interval' do
      expect do
        described_class.subscribe(customer, plan: :free, interval: :month)
      end.to raise_error(Belt::Pay::ConfigurationError, /no Stripe price for interval/)
    end
  end

  describe '.plan_for_price' do
    before do
      described_class.plans do
        plan(:pro) { name 'Pro'; price 49, interval: :month, stripe_price: 'price_pro_month' }
      end
    end

    it 'returns the plan owning a Stripe price id' do
      expect(described_class.plan_for_price('price_pro_month').key).to eq(:pro)
    end

    it 'returns nil for an unknown price id' do
      expect(described_class.plan_for_price('price_nope')).to be_nil
    end
  end

  describe '.reset_plans!' do
    it 'clears declared plans' do
      described_class.plans { plan(:pro) { name 'Pro' } }
      described_class.reset_plans!
      expect(described_class.plans.empty?).to be true
    end
  end
end
