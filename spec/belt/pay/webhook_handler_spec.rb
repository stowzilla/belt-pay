# frozen_string_literal: true

RSpec.describe Belt::Pay::WebhookHandler do
  let(:provider) { instance_double(Belt::Pay::Providers::Stripe) }
  let(:transaction_class) { Belt::Pay::Transaction }

  # Transactions kept in memory, keyed by id, with the one rule of the real table
  # that matters here: a second row with the same id is refused.
  let(:rows) { {} }

  before do
    Belt::Pay.reset_hooks!
    allow(Belt::Pay).to receive(:provider).and_return(provider)
    allow(Belt::Pay).to receive(:log)
    allow_any_instance_of(transaction_class).to receive(:save!).and_return(true)
    allow(transaction_class).to receive(:create!) do |attributes|
      row = transaction_class.new(attributes)
      if rows.key?(row.id)
        row.errors.add(:id, 'already exists')
        raise ActiveItem::RecordInvalid, row
      end
      rows[row.id] = row
    end
    allow(transaction_class).to receive(:lookup) { |id| rows[id] }
    allow(transaction_class).to receive(:for_session) do |session_id|
      rows.values.find { |row| row.provider_session_id == session_id }
    end
  end

  after { Belt::Pay.reset_hooks! }

  # Real Stripe objects, so a field the event doesn't carry behaves as it does in
  # production (a method call on it raises NoMethodError).
  def stripe_event(type, object)
    Stripe::Event.construct_from({ id: 'evt_1', object: 'event', type: type, data: { object: object } })
  end

  def deliver(type, object)
    event = stripe_event(type, object)
    allow(provider).to receive(:verify_webhook).and_return(event)
    described_class.process(payload: '{}', signature: 'sig')
  end

  def pending_row(session_id: 'cs_123', **attributes)
    rows['txn-1'] = transaction_class.new({ id: 'txn-1', customer_id: 'cust-1', provider_session_id: session_id,
                                            type: 'checkout', status: 'pending' }.merge(attributes))
  end

  def checkout_session(**overrides)
    { id: 'cs_123', object: 'checkout.session', metadata: { app_customer_id: 'cust-1' }, amount_total: 4999,
      currency: 'eur', payment_status: 'paid', payment_intent: 'pi_123' }.merge(overrides)
  end

  describe '.process' do
    let(:payload) { '{"id":"evt_123"}' }
    let(:signature) { 'whsec_sig_xxx' }
    let(:event) { stripe_event('checkout.session.completed', checkout_session) }

    it 'verifies the webhook signature via the provider' do
      expect(provider).to receive(:verify_webhook).with(payload, signature).and_return(event)
      described_class.process(payload: payload, signature: signature)
    end

    it 'returns { received: true } on success' do
      allow(provider).to receive(:verify_webhook).and_return(event)
      expect(described_class.process(payload: payload, signature: signature)).to eq({ received: true })
    end

    it 'raises when signature verification fails' do
      allow(provider).to receive(:verify_webhook)
        .and_raise(Stripe::SignatureVerificationError.new('invalid signature', 'sig_header'))
      expect { described_class.process(payload: payload, signature: signature) }
        .to raise_error(Stripe::SignatureVerificationError)
    end
  end

  describe 'EVENTS' do
    it 'subscribes to the async payment, refund and dispute events' do
      expect(described_class::EVENTS).to include(
        'checkout.session.async_payment_succeeded', 'checkout.session.async_payment_failed',
        'charge.refunded', 'charge.dispute.created', 'charge.dispute.closed'
      )
    end
  end

  describe 'checkout.session.completed' do
    context 'when a pending transaction exists' do
      before { pending_row }

      it 'marks the pending transaction as completed' do
        deliver('checkout.session.completed', checkout_session)
        expect(rows['txn-1']).to have_attributes(status: 'completed', amount_cents: 4999, currency: 'eur',
                                                 provider_payment_intent_id: 'pi_123')
      end

      it 'leaves it pending when the session is not paid yet' do
        deliver('checkout.session.completed', checkout_session(payment_status: 'unpaid'))
        expect(rows['txn-1'].status).to eq('pending')
      end

      it 'completes a session that needed no payment' do
        deliver('checkout.session.completed', checkout_session(payment_status: 'no_payment_required', amount_total: 0))
        expect(rows['txn-1'].status).to eq('completed')
      end
    end

    context 'when no pending transaction exists (webhook-first flow)' do
      it 'creates a completed checkout transaction keyed on the session id' do
        deliver('checkout.session.completed', checkout_session)
        expect(rows.keys).to eq(['cs_123'])
        expect(rows['cs_123']).to have_attributes(customer_id: 'cust-1', status: 'completed', amount_cents: 4999,
                                                  currency: 'eur', provider_session_id: 'cs_123')
      end

      it 'records an unpaid session as pending' do
        deliver('checkout.session.completed', checkout_session(payment_status: 'unpaid'))
        expect(rows['cs_123'].status).to eq('pending')
      end
    end

    context 'when the event is delivered again' do
      it 'does not add a second transaction' do
        2.times { deliver('checkout.session.completed', checkout_session) }
        expect(rows.size).to eq(1)
      end

      it 'does not add one when the row exists but the session index has not caught up' do
        deliver('checkout.session.completed', checkout_session)
        allow(transaction_class).to receive(:for_session).and_return(nil)
        deliver('checkout.session.completed', checkout_session)
        expect(rows.size).to eq(1)
      end

      it 'does not bring a refunded transaction back' do
        pending_row(status: 'refunded')
        deliver('checkout.session.completed', checkout_session)
        expect(rows.size).to eq(1)
        expect(rows['txn-1'].status).to eq('refunded')
      end
    end

    context 'when the session carries no app_customer_id' do
      it 'does not record a transaction' do
        deliver('checkout.session.completed', checkout_session(metadata: {}))
        expect(rows).to be_empty
      end
    end
  end

  describe 'checkout.session.async_payment_succeeded' do
    it 'completes the transaction an unpaid session left pending' do
      pending_row
      deliver('checkout.session.completed', checkout_session(payment_status: 'unpaid'))
      deliver('checkout.session.async_payment_succeeded', checkout_session)
      expect(rows['txn-1']).to have_attributes(status: 'completed', amount_cents: 4999)
    end
  end

  describe 'checkout.session.async_payment_failed' do
    it 'fails the pending transaction' do
      pending_row
      deliver('checkout.session.async_payment_failed', checkout_session(payment_status: 'unpaid'))
      expect(rows['txn-1']).to have_attributes(status: 'failed', description: 'Checkout payment failed')
    end
  end

  describe 'checkout.session.expired' do
    it 'marks a pending transaction as failed' do
      pending_row
      deliver('checkout.session.expired', checkout_session(payment_status: 'unpaid'))
      expect(rows['txn-1']).to have_attributes(status: 'failed', description: 'Checkout session expired')
    end

    it 'does nothing when there is no transaction' do
      expect { deliver('checkout.session.expired', checkout_session) }.not_to raise_error
      expect(rows).to be_empty
    end
  end

  describe 'invoice.paid' do
    def invoice(**overrides)
      { id: 'in_123', object: 'invoice', subscription: 'sub_456', metadata: { app_customer_id: 'cust-1' },
        amount_paid: 9900, currency: 'usd', billing_reason: 'subscription_cycle' }.merge(overrides)
    end

    it 'records a subscription renewal transaction keyed on the invoice id' do
      deliver('invoice.paid', invoice)
      expect(rows['in_123']).to have_attributes(
        customer_id: 'cust-1', provider_subscription_id: 'sub_456', type: 'subscription_renewal',
        status: 'completed', amount_cents: 9900,
        metadata: { invoice_id: 'in_123', billing_reason: 'subscription_cycle' }
      )
    end

    it 'records the invoice once however often it is delivered' do
      3.times { deliver('invoice.paid', invoice) }
      expect(rows.size).to eq(1)
    end

    it 'reads the subscription from parent.subscription_details on newer API versions' do
      deliver('invoice.paid', invoice(subscription: nil,
                                      parent: { subscription_details: { subscription: 'sub_new' } }))
      expect(rows['in_123'].provider_subscription_id).to eq('sub_new')
    end

    context 'when customer_id is not on invoice metadata' do
      it 'resolves customer_id from the subscription' do
        sub = Stripe::Subscription.construct_from({ id: 'sub_456', metadata: { app_customer_id: 'cust-2' } })
        allow(provider).to receive(:ensure_api_key!)
        allow(Stripe::Subscription).to receive(:retrieve).with('sub_456').and_return(sub)
        deliver('invoice.paid', invoice(metadata: {}))
        expect(rows['in_123'].customer_id).to eq('cust-2')
      end

      it 'rescues Stripe errors, logs a warning and records nothing' do
        allow(provider).to receive(:ensure_api_key!)
        allow(Stripe::Subscription).to receive(:retrieve)
          .and_raise(Stripe::InvalidRequestError.new('No such subscription', 'id'))
        expect(Belt::Pay).to receive(:log).with(
          :warn, 'Belt::Pay::WebhookHandler: failed to resolve customer from subscription',
          hash_including(subscription_id: 'sub_456')
        )
        expect { deliver('invoice.paid', invoice(metadata: {})) }.not_to raise_error
        expect(rows).to be_empty
      end
    end

    context 'when neither invoice nor subscription has customer_id' do
      it 'does not record a transaction' do
        deliver('invoice.paid', invoice(subscription: nil, metadata: {}))
        expect(rows).to be_empty
      end
    end
  end

  describe 'invoice.payment_failed' do
    it 'logs a warning' do
      expect(Belt::Pay).to receive(:log).with(:warn, 'Belt::Pay::WebhookHandler: invoice payment failed',
                                              customer_id: 'cust-1', invoice_id: 'in_fail_123')
      deliver('invoice.payment_failed', { id: 'in_fail_123', object: 'invoice', subscription: 'sub_456',
                                          metadata: { app_customer_id: 'cust-1' } })
    end
  end

  describe 'customer.subscription events' do
    let(:customer_class) do
      Struct.new(:id, :pay_subscription_id, :pay_plan) do
        def save(validate: true)
          (@saves ||= []) << validate
          true
        end

        def saves
          @saves || []
        end
      end
    end
    let(:customer) { customer_class.new('cust-1', 'sub_1', nil) }
    let(:model) { double('CustomerModel') }

    def subscription(**overrides)
      { id: 'sub_1', object: 'subscription', status: 'active',
        metadata: { app_customer_id: 'cust-1', plan: 'pro' } }.merge(overrides)
    end

    # What Stripe says the subscription is now, whatever the event carried.
    def stripe_has(**overrides)
      allow(provider).to receive(:retrieve_subscription).with('sub_1')
        .and_return(Stripe::Subscription.construct_from(subscription(**overrides)))
    end

    before do
      Belt::Pay.configuration.customer_class = model
      allow(model).to receive(:find).with('cust-1').and_return(customer)
    end

    it 'logs the update with status' do
      stripe_has(status: 'past_due')
      expect(Belt::Pay).to receive(:log).with(:info, 'Belt::Pay::WebhookHandler: subscription updated',
                                              customer_id: 'cust-1', subscription_id: 'sub_1', status: 'past_due')
      deliver('customer.subscription.updated', subscription(status: 'past_due'))
    end

    it 'logs the deletion' do
      stripe_has(status: 'canceled')
      expect(Belt::Pay).to receive(:log).with(:info, 'Belt::Pay::WebhookHandler: subscription deleted',
                                              customer_id: 'cust-1', subscription_id: 'sub_1')
      deliver('customer.subscription.deleted', subscription(status: 'canceled'))
    end

    it 'gives the customer the plan once the subscription is active' do
      stripe_has(status: 'active')
      deliver('customer.subscription.updated', subscription)
      expect(customer.pay_plan).to eq('pro')
      expect(customer.saves).to eq([false])
    end

    it 'gives the plan on a subscription created already trialing' do
      stripe_has(status: 'trialing')
      deliver('customer.subscription.created', subscription(status: 'trialing'))
      expect(customer.pay_plan).to eq('pro')
    end

    it 'resolves the plan from the price when the metadata names none' do
      Belt::Pay.plans { plan(:team) { price 49, stripe_price: 'price_team' } }
      stripe_has(metadata: { app_customer_id: 'cust-1' }, items: { data: [{ price: { id: 'price_team' } }] })
      deliver('customer.subscription.updated', subscription)
      expect(customer.pay_plan).to eq('team')
    end

    it 'adopts a subscription started through Checkout' do
      customer.pay_subscription_id = nil
      stripe_has(status: 'active')
      deliver('customer.subscription.created', subscription)
      expect(customer).to have_attributes(pay_subscription_id: 'sub_1', pay_plan: 'pro')
    end

    it 'grants nothing while the first payment is outstanding' do
      stripe_has(status: 'incomplete')
      deliver('customer.subscription.created', subscription(status: 'incomplete'))
      expect(customer.pay_plan).to be_nil
      expect(customer.saves).to be_empty
    end

    it 'keeps the plan while Stripe is retrying a failed payment' do
      customer.pay_plan = 'pro'
      stripe_has(status: 'past_due')
      deliver('customer.subscription.updated', subscription(status: 'past_due'))
      expect(customer.pay_plan).to eq('pro')
    end

    it 'takes the plan back when the subscription goes unpaid' do
      customer.pay_plan = 'pro'
      stripe_has(status: 'unpaid')
      deliver('customer.subscription.updated', subscription(status: 'unpaid'))
      expect(customer).to have_attributes(pay_plan: nil, pay_subscription_id: 'sub_1')
    end

    it 'takes the plan and the subscription back when it is deleted' do
      customer.pay_plan = 'pro'
      stripe_has(status: 'canceled')
      deliver('customer.subscription.deleted', subscription(status: 'canceled'))
      expect(customer).to have_attributes(pay_plan: nil, pay_subscription_id: nil)
    end

    it 'goes by what Stripe says now, not a stale event sent again' do
      customer.pay_plan = nil
      stripe_has(status: 'canceled')
      deliver('customer.subscription.updated', subscription(status: 'active'))
      expect(customer.pay_plan).to be_nil
    end

    it "leaves the plan alone when another subscription than the customer's ends" do
      customer.pay_subscription_id = 'sub_newer'
      customer.pay_plan = 'pro'
      stripe_has(status: 'canceled')
      deliver('customer.subscription.deleted', subscription(status: 'canceled'))
      expect(customer).to have_attributes(pay_plan: 'pro', pay_subscription_id: 'sub_newer')
    end

    it 'ignores a subscription with no app_customer_id without asking Stripe' do
      expect(provider).not_to receive(:retrieve_subscription)
      deliver('customer.subscription.updated', subscription(metadata: {}))
    end

    it 'logs an error and changes nothing when customer_class is not configured' do
      Belt::Pay.configuration.customer_class = nil
      stripe_has(status: 'active')
      expect(Belt::Pay).to receive(:log).with(:error, /customer_class is not configured/, customer_id: 'cust-1')
      deliver('customer.subscription.updated', subscription)
      expect(customer.pay_plan).to be_nil
    end

    it 'raises when Stripe cannot be asked, so the event is retried' do
      allow(provider).to receive(:retrieve_subscription).and_raise(Stripe::APIConnectionError.new('down'))
      expect { deliver('customer.subscription.updated', subscription) }.to raise_error(Stripe::APIConnectionError)
    end

    context 'with the transaction Subscription.create recorded' do
      before do
        rows['sub_1'] = transaction_class.new(id: 'sub_1', customer_id: 'cust-1', type: 'subscription',
                                              status: 'pending')
      end

      it 'completes it when the subscription becomes active' do
        stripe_has(status: 'active')
        deliver('customer.subscription.updated', subscription)
        expect(rows['sub_1'].status).to eq('completed')
      end

      it 'fails it when the first payment never arrives' do
        stripe_has(status: 'incomplete_expired')
        deliver('customer.subscription.updated', subscription(status: 'incomplete_expired'))
        expect(rows['sub_1'].status).to eq('failed')
      end

      it 'cancels it when the subscription ends' do
        rows['sub_1'].status = 'completed'
        stripe_has(status: 'canceled')
        deliver('customer.subscription.deleted', subscription(status: 'canceled'))
        expect(rows['sub_1'].status).to eq('canceled')
      end
    end
  end

  describe 'charge.refunded' do
    def charge(**overrides)
      { id: 'ch_1', object: 'charge', metadata: {}, payment_intent: 'pi_123', amount: 4999,
        amount_refunded: 4999, refunded: true }.merge(overrides)
    end

    before do
      pending_row(status: 'completed', amount_cents: 4999)
      allow(provider).to receive(:checkout_session_id_for).with('pi_123').and_return('cs_123')
    end

    it 'marks a fully refunded transaction as refunded' do
      deliver('charge.refunded', charge)
      expect(rows['txn-1']).to have_attributes(status: 'refunded', amount_refunded_cents: 4999)
    end

    it 'keeps a partly refunded transaction completed and records the amount' do
      deliver('charge.refunded', charge(amount_refunded: 1000, refunded: false))
      expect(rows['txn-1']).to have_attributes(status: 'completed', amount_refunded_cents: 1000)
    end

    it 'ignores a payment that did not come from one of our checkouts' do
      allow(provider).to receive(:checkout_session_id_for).and_return(nil)
      expect { deliver('charge.refunded', charge) }.not_to raise_error
      expect(rows['txn-1'].status).to eq('completed')
    end

    it 'raises when Stripe cannot be asked, so the event is retried' do
      allow(provider).to receive(:checkout_session_id_for).and_raise(Stripe::PermissionError.new('no access'))
      expect { deliver('charge.refunded', charge) }.to raise_error(Stripe::PermissionError)
    end

    it 'finds a renewal by the invoice the charge paid' do
      rows['in_9'] = transaction_class.new(id: 'in_9', customer_id: 'cust-1', type: 'subscription_renewal',
                                           status: 'completed')
      deliver('charge.refunded', charge(invoice: 'in_9'))
      expect(rows['in_9'].status).to eq('refunded')
      expect(rows['txn-1'].status).to eq('completed')
    end
  end

  describe 'charge.dispute' do
    def dispute(**overrides)
      { id: 'dp_1', object: 'dispute', charge: 'ch_1', payment_intent: 'pi_123', status: 'needs_response' }
        .merge(overrides)
    end

    before do
      pending_row(status: 'completed')
      allow(provider).to receive(:checkout_session_id_for).with('pi_123').and_return('cs_123')
    end

    it 'marks the transaction disputed when a dispute opens' do
      deliver('charge.dispute.created', dispute)
      expect(rows['txn-1']).to have_attributes(status: 'disputed', description: 'Payment disputed (dp_1)')
    end

    it 'completes it again when the dispute is won' do
      deliver('charge.dispute.created', dispute)
      deliver('charge.dispute.closed', dispute(status: 'won'))
      expect(rows['txn-1'].status).to eq('completed')
    end

    it 'marks it refunded when the dispute is lost' do
      deliver('charge.dispute.created', dispute)
      deliver('charge.dispute.closed', dispute(status: 'lost'))
      expect(rows['txn-1'].status).to eq('refunded')
    end
  end

  describe 'Belt::Pay.on hooks' do
    it 'runs after the bookkeeping with the event and its transaction' do
      pending_row
      seen = []
      Belt::Pay.on('checkout.session.completed') { |event, transaction| seen << [event.type, transaction.status] }
      deliver('checkout.session.completed', checkout_session)
      expect(seen).to eq([['checkout.session.completed', 'completed']])
    end

    it 'runs for event types the gem does nothing with, with no transaction' do
      seen = []
      Belt::Pay.on('payout.paid', 'payout.failed') { |event, transaction| seen << [event.type, transaction] }
      deliver('payout.paid', { id: 'po_1', object: 'payout' })
      expect(seen).to eq([['payout.paid', nil]])
    end

    it 'lets a failing hook fail the webhook so Stripe retries' do
      Belt::Pay.on('charge.refunded') { raise 'could not revoke' }
      allow(provider).to receive(:checkout_session_id_for).and_return(nil)
      expect { deliver('charge.refunded', { id: 'ch_1', object: 'charge', payment_intent: 'pi_1' }) }
        .to raise_error('could not revoke')
    end
  end

  describe 'unhandled event type' do
    it 'logs info and does not raise' do
      expect(Belt::Pay).to receive(:log).with(:info, 'Belt::Pay::WebhookHandler: unhandled event type',
                                              event_type: 'some.unknown.event')
      expect { deliver('some.unknown.event', { id: 'x_1', object: 'thing' }) }.not_to raise_error
    end
  end
end
