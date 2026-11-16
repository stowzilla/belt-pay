# frozen_string_literal: true

RSpec.describe Belt::Pay::Providers::Stripe do
  subject(:provider) { described_class.new }

  before do
    allow(Stripe).to receive(:api_key).and_return('sk_test_xxx')
  end

  describe '#ensure_api_key!' do
    it 'raises ConfigurationError when no key is available' do
      allow(Stripe).to receive(:api_key).and_return(nil)
      allow(provider).to receive(:fetch_api_key).and_return(nil)
      expect { provider.ensure_api_key! }.to raise_error(Belt::Pay::ConfigurationError)
    end

    it 'succeeds when api_key is already set' do
      expect { provider.ensure_api_key! }.not_to raise_error
    end

    it 'refuses the placeholder key the old Terraform template seeded' do
      allow(Stripe).to receive(:api_key).and_return(nil)
      allow(provider).to receive(:fetch_api_key).and_return('sk_test_PLACEHOLDER')
      expect(Stripe).not_to receive(:api_key=)
      expect { provider.ensure_api_key! }.to raise_error(Belt::Pay::ConfigurationError, /placeholder/)
    end

    it 'treats a blank key as not configured' do
      allow(Stripe).to receive(:api_key).and_return('')
      allow(provider).to receive(:fetch_api_key).and_return('  ')
      expect { provider.ensure_api_key! }.to raise_error(Belt::Pay::ConfigurationError, /not configured/)
    end

    it 'reads the key from the configured Secrets Manager secret' do
      Belt::Pay.configuration.secret_name = 'app-dev-stripe'
      client = instance_double(Aws::SecretsManager::Client)
      allow(Aws::SecretsManager::Client).to receive(:new).and_return(client)
      allow(client).to receive(:get_secret_value).with(secret_id: 'app-dev-stripe')
        .and_return(double(secret_string: '{"stripe_secret_key":"rk_test_real"}'))
      allow(Stripe).to receive(:api_key).and_return(nil)
      expect(Stripe).to receive(:api_key=).with('rk_test_real')
      provider.ensure_api_key!
    end
  end

  describe '#create_customer' do
    let(:customer) { double(id: 'cust-123', email: 'test@example.com') }

    it 'creates a Stripe customer with email and metadata' do
      stripe_customer = double(id: 'cus_new_123')
      expect(Stripe::Customer).to receive(:create).with(
        email: 'test@example.com',
        metadata: { app_customer_id: 'cust-123' }
      ).and_return(stripe_customer)

      expect(provider.create_customer(customer)).to eq('cus_new_123')
    end
  end

  describe '#subscription_active?' do
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

  describe '#create_checkout_session' do
    let(:session) { double(url: 'https://checkout.stripe.com/session/xxx', id: 'cs_123') }

    it 'creates a checkout session with correct params' do
      expect(Stripe::Checkout::Session).to receive(:create).with({
        customer: 'cus_stripe_123',
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        mode: 'subscription',
        success_url: 'https://example.com/success',
        cancel_url: 'https://example.com/cancel',
        metadata: { plan: 'pro' }
      }).and_return(session)

      result = provider.create_checkout_session('cus_stripe_123',
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        mode: 'subscription',
        success_url: 'https://example.com/success',
        cancel_url: 'https://example.com/cancel',
        metadata: { plan: 'pro' })

      expect(result).to eq({ url: 'https://checkout.stripe.com/session/xxx', session_id: 'cs_123' })
    end

    it 'defaults mode to payment' do
      expect(Stripe::Checkout::Session).to receive(:create).with(
        hash_including(mode: 'payment')
      ).and_return(session)

      provider.create_checkout_session('cus_stripe_123',
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        success_url: 'https://example.com/success',
        cancel_url: 'https://example.com/cancel')
    end

    it 'defaults metadata to empty hash' do
      expect(Stripe::Checkout::Session).to receive(:create).with(
        hash_including(metadata: {})
      ).and_return(session)

      provider.create_checkout_session('cus_stripe_123',
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        success_url: 'https://example.com/success',
        cancel_url: 'https://example.com/cancel')
    end

    it 'includes subscription_data when provided' do
      expect(Stripe::Checkout::Session).to receive(:create).with(
        hash_including(subscription_data: { trial_period_days: 14 })
      ).and_return(session)

      provider.create_checkout_session('cus_stripe_123',
        line_items: [{ price: 'price_xxx', quantity: 1 }],
        mode: 'subscription',
        success_url: 'https://example.com/success',
        cancel_url: 'https://example.com/cancel',
        subscription_data: { trial_period_days: 14 })
    end
  end

  describe '#create_subscription' do
    let(:subscription) do
      double(
        id: 'sub_new_789',
        status: 'active',
        current_period_end: 1756080000 # 2025-08-24T00:00:00Z
      )
    end

    it 'creates a subscription with correct params' do
      expect(Stripe::Subscription).to receive(:create).with({
        customer: 'cus_stripe_123',
        items: [{ price: 'price_xxx' }],
        metadata: { plan: 'pro' },
        payment_behavior: 'default_incomplete',
        expand: ['latest_invoice.payment_intent']
      }).and_return(subscription)

      result = provider.create_subscription('cus_stripe_123', price_id: 'price_xxx', metadata: { plan: 'pro' })

      expect(result[:subscription_id]).to eq('sub_new_789')
      expect(result[:status]).to eq('active')
      expect(result[:current_period_end]).to be_a(String)
    end

    it 'defaults metadata to empty hash' do
      expect(Stripe::Subscription).to receive(:create).with(
        hash_including(metadata: {})
      ).and_return(subscription)

      provider.create_subscription('cus_stripe_123', price_id: 'price_xxx')
    end
  end

  describe '#cancel_subscription' do
    context 'when immediately: true' do
      it 'cancels the subscription immediately' do
        expect(Stripe::Subscription).to receive(:cancel).with('sub_123')
        provider.cancel_subscription('sub_123', immediately: true)
      end
    end

    context 'when immediately: false (default)' do
      it 'sets cancel_at_period_end' do
        expect(Stripe::Subscription).to receive(:update).with(
          'sub_123', { cancel_at_period_end: true }
        )
        provider.cancel_subscription('sub_123', immediately: false)
      end
    end
  end

  describe '#billing_portal' do
    let(:customer) { double(pay_customer_id: 'cus_stripe_123') }
    let(:session) { double(url: 'https://billing.stripe.com/p/session/xxx') }

    it 'creates a billing portal session' do
      expect(Stripe::BillingPortal::Session).to receive(:create).with({
        customer: 'cus_stripe_123',
        return_url: 'https://app.example.com/settings'
      }).and_return(session)

      result = provider.billing_portal(customer, return_url: 'https://app.example.com/settings')
      expect(result).to eq({ url: 'https://billing.stripe.com/p/session/xxx' })
    end

    it 'raises Error when customer has no pay_customer_id' do
      customer_no_id = double(pay_customer_id: nil)
      expect { provider.billing_portal(customer_no_id, return_url: 'https://example.com') }
        .to raise_error(Belt::Pay::Error, 'Customer has no payment account')
    end
  end

  describe '#attach_payment_method' do
    it 'attaches the payment method and sets as default' do
      expect(Stripe::PaymentMethod).to receive(:attach).with('pm_xxx', { customer: 'cus_123' })
      expect(Stripe::Customer).to receive(:update).with('cus_123', {
        invoice_settings: { default_payment_method: 'pm_xxx' }
      })

      provider.attach_payment_method('cus_123', 'pm_xxx')
    end

    context 'when payment method is already attached' do
      it 'rescues and still sets as default (idempotent)' do
        allow(Stripe::PaymentMethod).to receive(:attach)
          .and_raise(Stripe::InvalidRequestError.new('has already been attached', 'payment_method'))

        expect(Stripe::Customer).to receive(:update).with('cus_123', {
          invoice_settings: { default_payment_method: 'pm_xxx' }
        })

        expect { provider.attach_payment_method('cus_123', 'pm_xxx') }.not_to raise_error
      end
    end

    context 'when a different InvalidRequestError occurs' do
      it 're-raises the error' do
        allow(Stripe::PaymentMethod).to receive(:attach)
          .and_raise(Stripe::InvalidRequestError.new('No such payment method', 'payment_method'))

        expect { provider.attach_payment_method('cus_123', 'pm_xxx') }
          .to raise_error(Stripe::InvalidRequestError, /No such payment method/)
      end
    end
  end

  describe '#payment_method_details' do
    let(:customer) { double(pay_customer_id: 'cus_stripe_123') }

    it 'returns card details for the default payment method' do
      stripe_customer = double(invoice_settings: double(default_payment_method: 'pm_456'))
      card = double(last4: '4242', brand: 'visa', exp_month: 12, exp_year: 2027)
      pm = double(card: card)

      allow(Stripe::Customer).to receive(:retrieve).with('cus_stripe_123').and_return(stripe_customer)
      allow(Stripe::PaymentMethod).to receive(:retrieve).with('pm_456').and_return(pm)

      result = provider.payment_method_details(customer)
      expect(result).to eq({ last4: '4242', brand: 'visa', exp_month: 12, exp_year: 2027 })
    end

    it 'returns nil when customer has no pay_customer_id' do
      customer_no_id = double(pay_customer_id: nil)
      expect(provider.payment_method_details(customer_no_id)).to be_nil
    end

    it 'returns nil when no default payment method is set' do
      stripe_customer = double(invoice_settings: double(default_payment_method: nil))
      allow(Stripe::Customer).to receive(:retrieve).with('cus_stripe_123').and_return(stripe_customer)

      expect(provider.payment_method_details(customer)).to be_nil
    end

    it 'returns nil when payment method has no card' do
      stripe_customer = double(invoice_settings: double(default_payment_method: 'pm_456'))
      pm = double(card: nil)

      allow(Stripe::Customer).to receive(:retrieve).with('cus_stripe_123').and_return(stripe_customer)
      allow(Stripe::PaymentMethod).to receive(:retrieve).with('pm_456').and_return(pm)

      expect(provider.payment_method_details(customer)).to be_nil
    end

    it 'returns nil on InvalidRequestError' do
      allow(Stripe::Customer).to receive(:retrieve)
        .and_raise(Stripe::InvalidRequestError.new('not found', 'id'))

      expect(provider.payment_method_details(customer)).to be_nil
    end
  end

  describe '#create_setup_intent' do
    it 'creates a setup intent with correct params' do
      setup_intent = double(client_secret: 'seti_xxx_secret_yyy', id: 'seti_123')
      expect(Stripe::SetupIntent).to receive(:create).with({
        customer: 'cus_stripe_123',
        payment_method_types: ['card'],
        usage: 'off_session',
        metadata: { app_customer_id: 'cust-123' }
      }).and_return(setup_intent)

      result = provider.create_setup_intent('cus_stripe_123', customer_id: 'cust-123')
      expect(result).to eq({ client_secret: 'seti_xxx_secret_yyy', setup_intent_id: 'seti_123' })
    end
  end

  describe '#verify_webhook with an unusable signing secret' do
    let(:payload) { '{"id":"evt_forged","object":"event","type":"checkout.session.completed"}' }

    # What an attacker can do: sign a made-up event with a secret they know.
    def signed_with(secret)
      timestamp = Time.now
      signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, secret)
      Stripe::Webhook::Signature.generate_header(timestamp, signature)
    end

    it 'refuses an event signed with the published placeholder secret' do
      allow(provider).to receive(:fetch_webhook_secret).and_return('whsec_PLACEHOLDER')
      expect { provider.verify_webhook(payload, signed_with('whsec_PLACEHOLDER')) }
        .to raise_error(Belt::Pay::ConfigurationError, /placeholder/)
    end

    ['', '   ', nil, 'not-a-signing-secret', 'whsec_'].each do |secret|
      it "refuses to verify against #{secret.inspect}" do
        allow(provider).to receive(:fetch_webhook_secret).and_return(secret)
        expect { provider.verify_webhook(payload, signed_with(secret.to_s)) }
          .to raise_error(Belt::Pay::ConfigurationError)
      end
    end

    it 'verifies an event signed with a real secret' do
      allow(provider).to receive(:fetch_webhook_secret).and_return('whsec_real123')
      expect(provider.verify_webhook(payload, signed_with('whsec_real123')).id).to eq('evt_forged')
    end

    it 'asks again after an unusable secret, so a warm Lambda picks up the fix' do
      allow(provider).to receive(:fetch_webhook_secret).and_return('whsec_PLACEHOLDER', 'whsec_real123')
      expect { provider.verify_webhook(payload, signed_with('whsec_PLACEHOLDER')) }
        .to raise_error(Belt::Pay::ConfigurationError)
      expect(provider.verify_webhook(payload, signed_with('whsec_real123')).id).to eq('evt_forged')
    end
  end

  describe '#checkout_session_id_for' do
    it 'asks Stripe which Checkout Session a payment came from' do
      expect(Stripe::Checkout::Session).to receive(:list).with({ payment_intent: 'pi_1', limit: 1 })
        .and_return(double(data: [double(id: 'cs_1')]))
      expect(provider.checkout_session_id_for('pi_1')).to eq('cs_1')
    end

    it 'is nil for a payment that did not come from Checkout' do
      allow(Stripe::Checkout::Session).to receive(:list).and_return(double(data: []))
      expect(provider.checkout_session_id_for('pi_1')).to be_nil
    end
  end

  describe '#verify_webhook' do
    it 'delegates to Stripe::Webhook.construct_event' do
      allow(provider).to receive(:webhook_signing_secret).and_return('whsec_test')
      event = double('Event')
      expect(Stripe::Webhook).to receive(:construct_event).with(
        '{"id":"evt_123"}', 'sig_header', 'whsec_test'
      ).and_return(event)

      expect(provider.verify_webhook('{"id":"evt_123"}', 'sig_header')).to eq(event)
    end

    it 'raises SignatureVerificationError on invalid signature' do
      allow(provider).to receive(:webhook_signing_secret).and_return('whsec_test')
      allow(Stripe::Webhook).to receive(:construct_event)
        .and_raise(Stripe::SignatureVerificationError.new('invalid', 'sig'))

      expect { provider.verify_webhook('{}', 'bad_sig') }
        .to raise_error(Stripe::SignatureVerificationError)
    end
  end
end
