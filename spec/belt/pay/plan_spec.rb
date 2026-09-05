# frozen_string_literal: true

RSpec.describe Belt::Pay::Plan do
  describe 'DSL declaration' do
    subject(:plan) do
      described_class.new(:pro).tap do |p|
        p.instance_eval do
          name        'Pro'
          description 'For growing teams'
          featured
          price 49,  interval: :month, stripe_price: 'price_month_123'
          price 490, interval: :year,  stripe_price: 'price_year_123'
          limit :projects, 25
          limit :seats, :unlimited
          feature :sso, :audit_logs
        end
      end
    end

    it 'captures marketing metadata' do
      expect(plan.name).to eq('Pro')
      expect(plan.description).to eq('For growing teams')
      expect(plan.featured?).to be true
    end

    it 'stores prices in cents per interval' do
      expect(plan.amount_cents(interval: :month)).to eq(4900)
      expect(plan.amount_cents(interval: :year)).to eq(49_000)
      expect(plan.amount(interval: :month)).to eq(49.0)
    end

    it 'resolves stripe price IDs per interval' do
      expect(plan.stripe_price_id(interval: :month)).to eq('price_month_123')
      expect(plan.stripe_price_id(interval: :year)).to eq('price_year_123')
    end

    it 'falls back to the first price when interval is missing' do
      expect(plan.stripe_price_id(interval: :week)).to eq('price_month_123')
    end

    it 'reports declared intervals' do
      expect(plan.intervals).to contain_exactly(:month, :year)
    end

    it 'is not free when it has a non-zero price' do
      expect(plan.free?).to be false
    end
  end

  describe 'limits' do
    subject(:plan) do
      described_class.new(:pro).tap do |p|
        p.instance_eval do
          limit :projects, 3
          limit :seats, :unlimited
        end
      end
    end

    it 'reads a numeric limit' do
      expect(plan.limit(:projects)).to eq(3)
    end

    it 'reads an unlimited limit as the sentinel' do
      expect(plan.limit(:seats)).to eq(:unlimited)
    end

    it 'returns nil for an undeclared limit' do
      expect(plan.limit(:webhooks)).to be_nil
    end

    it 'allows usage strictly under a numeric ceiling' do
      expect(plan.allows?(:projects, 0)).to be true
      expect(plan.allows?(:projects, 2)).to be true
      expect(plan.allows?(:projects, 3)).to be false
      expect(plan.allows?(:projects, 4)).to be false
    end

    it 'always allows unlimited limits' do
      expect(plan.allows?(:seats, 10_000)).to be true
    end

    it 'always allows undeclared limits' do
      expect(plan.allows?(:webhooks, 999)).to be true
    end

    it 'coerces string limit values to integers' do
      plan.limit(:projects, '10')
      expect(plan.limit(:projects)).to eq(10)
    end
  end

  describe 'features' do
    subject(:plan) do
      described_class.new(:pro).tap { |p| p.feature(:sso) }
    end

    it 'reports included features' do
      expect(plan.includes_feature?(:sso)).to be true
    end

    it 'reports missing features' do
      expect(plan.includes_feature?(:audit_logs)).to be false
    end
  end

  describe '#free?' do
    it 'is true with no prices' do
      expect(described_class.new(:free).free?).to be true
    end

    it 'is true when all prices are zero' do
      plan = described_class.new(:free).tap { |p| p.price(0) }
      expect(plan.free?).to be true
    end
  end

  describe '#to_h' do
    subject(:plan) do
      described_class.new(:pro).tap do |p|
        p.instance_eval do
          name 'Pro'
          price 49, interval: :month, stripe_price: 'price_x'
          limit :projects, 25
          limit :seats, :unlimited
          feature :sso
        end
      end
    end

    it 'serializes for the frontend' do
      h = plan.to_h
      expect(h[:key]).to eq('pro')
      expect(h[:name]).to eq('Pro')
      expect(h[:limits]).to eq(projects: 25, seats: 'unlimited')
      expect(h[:features]).to eq(['sso'])
      expect(h[:free]).to be false
    end
  end
end
