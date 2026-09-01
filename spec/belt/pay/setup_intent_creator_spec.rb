# frozen_string_literal: true

RSpec.describe Belt::Pay::SetupIntentCreator do
  let(:provider) { instance_double(Belt::Pay::Providers::Stripe) }
  let(:customer) do
    double('Customer',
           id: 'cust-123',
           email: 'test@example.com',
           pay_customer_id: 'cus_stripe_123',
           class: double(find: nil))
  end
  let(:provisioner) { double('Provisioner', call: 'cus_stripe_123') }

  before do
    allow(Belt::Pay).to receive(:provider).and_return(provider)
    allow(Belt::Pay).to receive(:log)
    allow(Belt::Pay::CustomerProvisioner).to receive(:new).and_return(provisioner)
    allow(provider).to receive(:create_setup_intent).and_return(
      { client_secret: 'seti_xxx_secret_yyy', setup_intent_id: 'seti_xxx' }
    )
  end

  describe '#call' do
    subject(:creator) { described_class.new(customer) }

    it 'ensures customer is provisioned' do
      expect(provisioner).to receive(:call).and_return('cus_stripe_123')
      creator.call
    end

    it 'creates a setup intent via the provider' do
      expect(provider).to receive(:create_setup_intent).with(
        'cus_stripe_123',
        customer_id: 'cust-123'
      ).and_return({ client_secret: 'seti_xxx_secret_yyy', setup_intent_id: 'seti_xxx' })
      creator.call
    end

    it 'returns a Result with client_secret and pay_customer_id' do
      result = creator.call
      expect(result.client_secret).to eq('seti_xxx_secret_yyy')
      expect(result.pay_customer_id).to eq('cus_stripe_123')
    end
  end
end
