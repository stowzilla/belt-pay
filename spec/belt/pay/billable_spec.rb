# frozen_string_literal: true

RSpec.describe Belt::Pay::Billable do
  let(:model_class) do
    Class.new do
      include Belt::Pay::Billable

      attr_accessor :id, :email

      def initialize(id:, email: nil)
        @id = id
        @email = email
      end

      def save(validate: true)
        true
      end

      def self.find(id)
        new(id: id)
      end
    end
  end

  let(:customer) { model_class.new(id: 'cust-123', email: 'test@example.com') }

  describe 'included attributes' do
    it 'adds pay_customer_id accessor' do
      customer.pay_customer_id = 'cus_stripe_123'
      expect(customer.pay_customer_id).to eq('cus_stripe_123')
    end

    it 'adds pay_subscription_id accessor' do
      customer.pay_subscription_id = 'sub_123'
      expect(customer.pay_subscription_id).to eq('sub_123')
    end

    it 'adds pay_payment_method_id accessor' do
      customer.pay_payment_method_id = 'pm_123'
      expect(customer.pay_payment_method_id).to eq('pm_123')
    end

    it 'adds pay_plan accessor' do
      customer.pay_plan = 'pro'
      expect(customer.pay_plan).to eq('pro')
    end
  end

  describe '#ensure_pay_customer!' do
    it 'delegates to Belt::Pay.ensure_customer' do
      expect(Belt::Pay).to receive(:ensure_customer).with(customer).and_return('cus_new')
      expect(customer.ensure_pay_customer!).to eq('cus_new')
    end
  end

  describe '#active_subscription?' do
    it 'returns false when no subscription' do
      expect(customer.active_subscription?).to be false
    end

    it 'checks with provider when subscription exists' do
      customer.pay_subscription_id = 'sub_123'
      expect(Belt::Pay::Subscription).to receive(:active?).with(customer).and_return(true)
      expect(customer.active_subscription?).to be true
    end
  end

  describe '#subscribe!' do
    let(:subscribe_result) { { subscription_id: 'sub_new_789', status: 'active' } }

    before do
      allow(Belt::Pay).to receive(:subscribe).and_return(subscribe_result)
    end

    it 'delegates to Belt::Pay.subscribe with price_id and metadata' do
      expect(Belt::Pay).to receive(:subscribe).with(
        customer, plan: nil, price_id: 'price_xxx', interval: :month, metadata: { plan: 'pro' }
      ).and_return(subscribe_result)

      customer.subscribe!(price_id: 'price_xxx', metadata: { plan: 'pro' })
    end

    it 'delegates to Belt::Pay.subscribe with a plan key and records the plan' do
      expect(Belt::Pay).to receive(:subscribe).with(
        customer, plan: :pro, price_id: nil, interval: :year, metadata: {}
      ).and_return(subscribe_result)

      customer.subscribe!(plan: :pro, interval: :year)
      expect(customer.pay_plan).to eq('pro')
    end

    it 'sets pay_subscription_id from the result' do
      customer.subscribe!(price_id: 'price_xxx')
      expect(customer.pay_subscription_id).to eq('sub_new_789')
    end

    it 'calls save after setting the subscription id' do
      expect(customer).to receive(:save).with(validate: false).and_return(true)
      customer.subscribe!(price_id: 'price_xxx')
    end

    it 'returns the subscription result' do
      result = customer.subscribe!(price_id: 'price_xxx')
      expect(result).to eq(subscribe_result)
    end

    it 'defaults metadata to empty hash' do
      expect(Belt::Pay).to receive(:subscribe).with(
        customer, plan: nil, price_id: 'price_xxx', interval: :month, metadata: {}
      ).and_return(subscribe_result)

      customer.subscribe!(price_id: 'price_xxx')
    end
  end

  describe 'plan awareness' do
    before do
      Belt::Pay.plans do
        plan(:free) { name 'Free'; limit :projects, 1 }
        plan(:pro) do
          name 'Pro'
          limit :projects, :unlimited
          feature :sso
        end
      end
    end

    it 'returns nil plan when not subscribed to one' do
      expect(customer.plan).to be_nil
    end

    it 'resolves the plan from pay_plan' do
      customer.pay_plan = 'pro'
      expect(customer.plan.key).to eq(:pro)
    end

    it 'answers on_plan?' do
      customer.pay_plan = 'pro'
      expect(customer.on_plan?(:pro)).to be true
      expect(customer.on_plan?(:free)).to be false
    end

    it 'gates features via plan_allows?' do
      customer.pay_plan = 'pro'
      expect(customer.plan_allows?(:sso)).to be true
      customer.pay_plan = 'free'
      expect(customer.plan_allows?(:sso)).to be false
    end

    it 'checks numeric limits via within_limit?' do
      customer.pay_plan = 'free'
      expect(customer.within_limit?(:projects, 0)).to be true
      expect(customer.within_limit?(:projects, 1)).to be false
    end

    it 'treats unlimited limits as always within' do
      customer.pay_plan = 'pro'
      expect(customer.within_limit?(:projects, 999)).to be true
    end

    it 'treats no plan as unlimited' do
      expect(customer.within_limit?(:projects, 999)).to be true
    end
  end

  describe '#cancel_subscription!' do
    before do
      customer.pay_subscription_id = 'sub_123'
      allow(Belt::Pay).to receive(:cancel_subscription)
    end

    it 'delegates to Belt::Pay.cancel_subscription' do
      expect(Belt::Pay).to receive(:cancel_subscription).with(customer, immediately: false)
      customer.cancel_subscription!
    end

    it 'passes immediately flag' do
      expect(Belt::Pay).to receive(:cancel_subscription).with(customer, immediately: true)
      customer.cancel_subscription!(immediately: true)
    end

    context 'when immediately: false (default)' do
      it 'does not nil out pay_subscription_id' do
        customer.cancel_subscription!
        expect(customer.pay_subscription_id).to eq('sub_123')
      end

      it 'does not call save' do
        expect(customer).not_to receive(:save).with(validate: false)
        customer.cancel_subscription!
      end
    end

    context 'when immediately: true' do
      it 'nils out pay_subscription_id' do
        customer.cancel_subscription!(immediately: true)
        expect(customer.pay_subscription_id).to be_nil
      end

      it 'calls save' do
        expect(customer).to receive(:save).with(validate: false).and_return(true)
        customer.cancel_subscription!(immediately: true)
      end
    end
  end

  describe '#billing_portal_url' do
    it 'delegates to Belt::Pay.billing_portal with return_url' do
      expect(Belt::Pay).to receive(:billing_portal).with(
        customer, return_url: 'https://app.example.com/settings'
      ).and_return({ url: 'https://billing.stripe.com/p/session/xxx' })

      result = customer.billing_portal_url(return_url: 'https://app.example.com/settings')
      expect(result).to eq({ url: 'https://billing.stripe.com/p/session/xxx' })
    end
  end

  describe '#attach_payment_method' do
    it 'delegates to Belt::Pay.attach_payment_method' do
      result = double('Result')
      expect(Belt::Pay).to receive(:attach_payment_method).with(customer, 'pm_xxx').and_return(result)

      expect(customer.attach_payment_method('pm_xxx')).to eq(result)
    end
  end

  describe '#create_setup_intent' do
    it 'delegates to Belt::Pay.create_setup_intent' do
      result = double('Result', client_secret: 'seti_xxx_secret_yyy')
      expect(Belt::Pay).to receive(:create_setup_intent).with(customer).and_return(result)

      expect(customer.create_setup_intent).to eq(result)
    end
  end

  describe '#payment_method_details' do
    let(:provider) { instance_double(Belt::Pay::Providers::Stripe) }

    before do
      allow(Belt::Pay).to receive(:provider).and_return(provider)
    end

    it 'delegates to the provider' do
      details = { last4: '4242', brand: 'visa', exp_month: 12, exp_year: 2027 }
      expect(provider).to receive(:payment_method_details).with(customer).and_return(details)

      expect(customer.payment_method_details).to eq(details)
    end

    it 'returns nil when provider returns nil' do
      expect(provider).to receive(:payment_method_details).with(customer).and_return(nil)

      expect(customer.payment_method_details).to be_nil
    end
  end

  describe '#transactions' do
    it 'delegates to Transaction.for_customer with the customer id' do
      transactions = [double('Txn1'), double('Txn2')]
      expect(Belt::Pay::Transaction).to receive(:for_customer).with('cust-123').and_return(transactions)

      expect(customer.transactions).to eq(transactions)
    end
  end
end
