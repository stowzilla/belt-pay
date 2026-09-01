# frozen_string_literal: true

RSpec.describe Belt::Pay::Checkout do
  let(:provider) { instance_double(Belt::Pay::Providers::Stripe) }
  let(:customer) do
    double(id: 'cust-123', email: 'test@example.com', pay_customer_id: 'cus_stripe_123', save: true)
  end
  let(:provisioner) { instance_double(Belt::Pay::CustomerProvisioner, call: 'cus_stripe_123') }

  before do
    allow(Belt::Pay).to receive(:provider).and_return(provider)
    allow(Belt::Pay).to receive(:log)
    allow(Belt::Pay::CustomerProvisioner).to receive(:new).and_return(provisioner)
  end

  describe '.create' do
    let(:checkout_result) { { url: 'https://checkout.stripe.com/session/xxx', session_id: 'cs_123' } }

    before do
      allow(provider).to receive(:create_checkout_session).and_return(checkout_result)
      allow(Belt::Pay::Transaction).to receive(:create!).and_return(double)
    end

    it 'provisions the customer first' do
      expect(Belt::Pay::CustomerProvisioner).to receive(:new).with(customer).and_return(provisioner)
      expect(provisioner).to receive(:call)

      described_class.create(customer,
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        success_url: 'https://app.example.com/success',
        cancel_url: 'https://app.example.com/cancel')
    end

    it 'calls provider with correct params for subscription mode' do
      expect(provider).to receive(:create_checkout_session).with(
        'cus_stripe_123',
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        mode: 'subscription',
        success_url: 'https://app.example.com/success',
        cancel_url: 'https://app.example.com/cancel',
        metadata: { app_customer_id: 'cust-123', plan: 'pro' }
      ).and_return(checkout_result)

      described_class.create(customer,
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        mode: 'subscription',
        success_url: 'https://app.example.com/success',
        cancel_url: 'https://app.example.com/cancel',
        metadata: { plan: 'pro' })
    end

    it 'records a pending subscription transaction' do
      expect(Belt::Pay::Transaction).to receive(:create!).with(
        hash_including(
          customer_id: 'cust-123',
          provider_session_id: 'cs_123',
          type: 'subscription',
          status: 'pending',
          currency: 'usd'
        )
      )

      described_class.create(customer,
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        mode: 'subscription',
        success_url: 'https://app.example.com/success',
        cancel_url: 'https://app.example.com/cancel')
    end

    it 'records type as checkout for payment mode' do
      expect(Belt::Pay::Transaction).to receive(:create!).with(
        hash_including(type: 'checkout')
      )

      described_class.create(customer,
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        mode: 'payment',
        success_url: 'https://app.example.com/success',
        cancel_url: 'https://app.example.com/cancel')
    end

    it 'returns the checkout result with url and session_id' do
      result = described_class.create(customer,
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        success_url: 'https://app.example.com/success',
        cancel_url: 'https://app.example.com/cancel')

      expect(result).to eq({ url: 'https://checkout.stripe.com/session/xxx', session_id: 'cs_123' })
    end

    it 'merges app_customer_id into metadata' do
      expect(provider).to receive(:create_checkout_session).with(
        anything,
        hash_including(metadata: { app_customer_id: 'cust-123' })
      ).and_return(checkout_result)

      described_class.create(customer,
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        success_url: 'https://app.example.com/success',
        cancel_url: 'https://app.example.com/cancel')
    end

    it 'logs the session creation' do
      expect(Belt::Pay).to receive(:log).with(:info, 'Belt::Pay::Checkout: session created',
                                              hash_including(customer_id: 'cust-123', session_id: 'cs_123'))

      described_class.create(customer,
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        success_url: 'https://app.example.com/success',
        cancel_url: 'https://app.example.com/cancel')
    end

    context 'when CustomerProvisioner raises' do
      it 'propagates the error' do
        allow(provisioner).to receive(:call).and_raise(Belt::Pay::Error, 'Provisioning failed')

        expect {
          described_class.create(customer,
            line_items: [{ price: 'price_xxx', quantity: 1 }],
            success_url: 'https://app.example.com/success',
            cancel_url: 'https://app.example.com/cancel')
        }.to raise_error(Belt::Pay::Error, 'Provisioning failed')
      end
    end

    context 'when provider raises' do
      it 'propagates the error' do
        allow(provider).to receive(:create_checkout_session)
          .and_raise(Stripe::InvalidRequestError.new('Invalid price', 'price'))

        expect {
          described_class.create(customer,
            line_items: [{ price: 'price_invalid', quantity: 1 }],
            success_url: 'https://app.example.com/success',
            cancel_url: 'https://app.example.com/cancel')
        }.to raise_error(Stripe::InvalidRequestError)
      end
    end
  end
end
