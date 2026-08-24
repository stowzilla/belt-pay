# frozen_string_literal: true

RSpec.describe Belt::Pay::Transaction do
  before do
    Belt::Pay.configure do |config|
      config.table_name_prefix = 'testapp-test'
    end
  end

  describe 'constants' do
    it 'defines valid types' do
      expect(described_class::TYPES).to include('checkout', 'subscription', 'subscription_renewal', 'refund')
    end

    it 'defines valid statuses' do
      expect(described_class::STATUSES).to include('pending', 'completed', 'failed', 'refunded', 'canceled')
    end
  end

  describe 'validations' do
    it 'requires customer_id' do
      txn = described_class.new
      txn.type = 'checkout'
      txn.status = 'pending'
      expect(txn).not_to be_valid
      expect(txn.errors[:customer_id]).to include("can't be blank")
    end

    it 'requires type' do
      txn = described_class.new
      txn.customer_id = 'cust-123'
      txn.status = 'pending'
      expect(txn).not_to be_valid
      expect(txn.errors[:type]).to include("can't be blank")
    end

    it 'requires status' do
      txn = described_class.new
      txn.customer_id = 'cust-123'
      txn.type = 'checkout'
      expect(txn).not_to be_valid
      expect(txn.errors[:status]).to include("can't be blank")
    end

    it 'is valid with all required fields' do
      txn = described_class.new
      txn.customer_id = 'cust-123'
      txn.type = 'checkout'
      txn.status = 'pending'
      expect(txn).to be_valid
    end
  end

  describe 'lifecycle callbacks' do
    let(:txn) do
      t = described_class.new
      t.customer_id = 'cust-123'
      t.type = 'checkout'
      t.status = 'pending'
      t
    end

    # Test callbacks by calling save with persistence stubbed
    before do
      allow(txn).to receive(:persist!).and_return(true) if txn.respond_to?(:persist!, true)
    end

    describe 'before_create' do
      it 'generates a UUID id' do
        # Simulate the before_create callback by calling save (which triggers create for new records)
        # We need to stub the DynamoDB write
        allow(txn).to receive(:new_record?).and_return(true)
        txn.run_callbacks(:create) { }
        expect(txn.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
      end

      it 'does not overwrite an existing id' do
        txn.id = 'custom-id-999'
        txn.run_callbacks(:create) { }
        expect(txn.id).to eq('custom-id-999')
      end

      it 'sets created_at timestamp' do
        txn.run_callbacks(:create) { }
        expect(txn.created_at).not_to be_nil
        expect(txn.created_at).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
      end

      it 'does not overwrite existing created_at' do
        txn.created_at = '2025-01-01T00:00:00Z'
        txn.run_callbacks(:create) { }
        expect(txn.created_at).to eq('2025-01-01T00:00:00Z')
      end
    end

    describe 'before_save' do
      it 'sets updated_at timestamp' do
        txn.run_callbacks(:save) { }
        expect(txn.updated_at).not_to be_nil
        expect(txn.updated_at).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
      end
    end
  end

  describe '.record_checkout' do
    before do
      allow(described_class).to receive(:create!) do |attrs|
        t = described_class.new
        attrs.each { |k, v| t.public_send(:"#{k}=", v) }
        t
      end
    end

    it 'creates a completed checkout transaction' do
      expect(described_class).to receive(:create!).with(
        hash_including(
          customer_id: 'cust-123',
          provider_session_id: 'cs_123',
          type: 'checkout',
          status: 'completed',
          amount_cents: 5000,
          currency: 'usd'
        )
      )

      described_class.record_checkout(
        customer_id: 'cust-123',
        session_id: 'cs_123',
        amount_cents: 5000
      )
    end

    it 'defaults currency to usd' do
      expect(described_class).to receive(:create!).with(hash_including(currency: 'usd'))
      described_class.record_checkout(customer_id: 'c', session_id: 's', amount_cents: 100)
    end

    it 'allows custom currency' do
      expect(described_class).to receive(:create!).with(hash_including(currency: 'eur'))
      described_class.record_checkout(customer_id: 'c', session_id: 's', amount_cents: 100, currency: 'eur')
    end
  end

  describe '.record_subscription' do
    before do
      allow(described_class).to receive(:create!) do |attrs|
        t = described_class.new
        attrs.each { |k, v| t.public_send(:"#{k}=", v) }
        t
      end
    end

    it 'creates a completed subscription transaction' do
      expect(described_class).to receive(:create!).with(
        hash_including(
          customer_id: 'cust-123',
          provider_subscription_id: 'sub_789',
          type: 'subscription',
          status: 'completed',
          amount_cents: 0
        )
      )

      described_class.record_subscription(
        customer_id: 'cust-123',
        subscription_id: 'sub_789',
        amount_cents: 0
      )
    end
  end

  describe '.record_renewal' do
    before do
      allow(described_class).to receive(:create!) do |attrs|
        t = described_class.new
        attrs.each { |k, v| t.public_send(:"#{k}=", v) }
        t
      end
    end

    it 'creates a subscription_renewal transaction' do
      expect(described_class).to receive(:create!).with(
        hash_including(
          customer_id: 'cust-123',
          provider_subscription_id: 'sub_789',
          type: 'subscription_renewal',
          status: 'completed',
          amount_cents: 9900
        )
      )

      described_class.record_renewal(
        customer_id: 'cust-123',
        subscription_id: 'sub_789',
        amount_cents: 9900
      )
    end
  end

  describe '.record_refund' do
    before do
      allow(described_class).to receive(:create!) do |attrs|
        t = described_class.new
        attrs.each { |k, v| t.public_send(:"#{k}=", v) }
        t
      end
    end

    it 'creates a refund transaction' do
      expect(described_class).to receive(:create!).with(
        hash_including(
          customer_id: 'cust-123',
          type: 'refund',
          status: 'completed',
          amount_cents: 2500
        )
      )

      described_class.record_refund(customer_id: 'cust-123', amount_cents: 2500)
    end

    it 'accepts custom currency' do
      expect(described_class).to receive(:create!).with(hash_including(currency: 'gbp'))
      described_class.record_refund(customer_id: 'c', amount_cents: 100, currency: 'gbp')
    end
  end

  describe '.for_customer' do
    it 'queries with customer_id and CustomerIndex' do
      expect(described_class).to receive(:where).with(
        customer_id: 'cust-123',
        index: 'CustomerIndex'
      ).and_return([])

      described_class.for_customer('cust-123')
    end
  end
end
