# frozen_string_literal: true

RSpec.describe Belt::Pay::PaymentMethodAttacher do
  let(:provider) { instance_double(Belt::Pay::Providers::Stripe) }
  let(:customer) do
    double(
      id: 'cust-123',
      email: 'test@example.com',
      pay_customer_id: 'cus_stripe_123',
      :pay_payment_method_id= => nil,
      save: true
    )
  end
  let(:provisioner) { instance_double(Belt::Pay::CustomerProvisioner, call: 'cus_stripe_123') }

  before do
    allow(Belt::Pay).to receive(:provider).and_return(provider)
    allow(Belt::Pay).to receive(:log)
    allow(Belt::Pay::CustomerProvisioner).to receive(:new).and_return(provisioner)
    allow(provider).to receive(:attach_payment_method)
  end

  describe '#call' do
    it 'provisions the customer' do
      expect(Belt::Pay::CustomerProvisioner).to receive(:new).with(customer).and_return(provisioner)
      expect(provisioner).to receive(:call)

      allow(customer).to receive(:save).with(validate: false).and_return(true)
      described_class.new(customer, 'pm_new_456').call
    end

    it 'attaches the payment method via provider' do
      allow(customer).to receive(:save).with(validate: false).and_return(true)
      expect(provider).to receive(:attach_payment_method).with('cus_stripe_123', 'pm_new_456')
      described_class.new(customer, 'pm_new_456').call
    end

    it 'persists the payment method id on the customer' do
      expect(customer).to receive(:pay_payment_method_id=).with('pm_new_456')
      expect(customer).to receive(:save).with(validate: false).and_return(true)
      described_class.new(customer, 'pm_new_456').call
    end

    it 'returns a Result with pay_customer_id and payment_method_id' do
      allow(customer).to receive(:save).with(validate: false).and_return(true)
      result = described_class.new(customer, 'pm_new_456').call

      expect(result).to be_a(Belt::Pay::PaymentMethodAttacher::Result)
      expect(result.pay_customer_id).to eq('cus_stripe_123')
      expect(result.payment_method_id).to eq('pm_new_456')
    end

    it 'logs completion' do
      allow(customer).to receive(:save).with(validate: false).and_return(true)
      expect(Belt::Pay).to receive(:log).with(:info, 'Belt::Pay::PaymentMethodAttacher: completed',
                                              hash_including(payment_method_id: 'pm_new_456'))
      described_class.new(customer, 'pm_new_456').call
    end

    context 'when save fails' do
      before do
        allow(customer).to receive(:save).with(validate: false).and_return(false)
      end

      it 'raises an error' do
        expect {
          described_class.new(customer, 'pm_new_456').call
        }.to raise_error(Belt::Pay::Error, /failed to persist payment_method_id/)
      end
    end
  end
end
