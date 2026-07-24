# frozen_string_literal: true

RSpec.describe Belt::Pay::CustomerProvisioner do
  let(:model_class) do
    Class.new do
      include Belt::Pay::Billable

      attr_accessor :id, :email

      def initialize(id:, email: nil, pay_customer_id: nil)
        @id = id
        @email = email
        @pay_customer_id = pay_customer_id
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

  describe '#call' do
    it 'returns existing pay_customer_id if already set' do
      customer.pay_customer_id = 'cus_existing'
      result = described_class.new(customer).call
      expect(result).to eq('cus_existing')
    end

    it 'creates a new provider customer when none exists' do
      provider = instance_double(Belt::Pay::Providers::Stripe)
      allow(Belt::Pay).to receive(:provider).and_return(provider)
      allow(provider).to receive(:create_customer).and_return('cus_new_123')
      allow(model_class).to receive(:find).and_return(model_class.new(id: 'cust-123'))

      result = described_class.new(customer).call
      expect(result).to eq('cus_new_123')
      expect(customer.pay_customer_id).to eq('cus_new_123')
    end
  end
end
