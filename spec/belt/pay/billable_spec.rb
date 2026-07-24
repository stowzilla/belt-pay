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
end
