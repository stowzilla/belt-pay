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

    it 'un-features a plan when featured is set to false' do
      expect { plan.featured(false) }.to change(plan, :featured?).from(true).to(false)
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

    it 'raises when a limit value is not a valid integer' do
      expect { plan.limit(:projects, 'lots') }.to raise_error(ArgumentError)
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

    it 'accepts multiple features in one call' do
      plan.feature(:audit_logs, :priority_support)
      expect(plan.features).to contain_exactly(:sso, :audit_logs, :priority_support)
    end

    it 'accumulates features across multiple calls' do
      plan.feature(:audit_logs)
      plan.feature(:webhooks)
      expect(plan.features).to contain_exactly(:sso, :audit_logs, :webhooks)
    end

    it 'coerces string feature names to symbols' do
      plan.feature('teams')
      expect(plan.includes_feature?('teams')).to be true
      expect(plan.includes_feature?(:teams)).to be true
    end

    it 'returns a copy of features that cannot mutate internal state' do
      plan.features << :hacked
      expect(plan.includes_feature?(:hacked)).to be false
    end
  end

  describe 'metadata' do
    subject(:plan) { described_class.new(:pro) }

    it 'defaults to an empty hash' do
      expect(plan.metadata).to eq({})
    end

    it 'merges metadata across calls' do
      plan.metadata(trial_days: 14)
      plan.metadata(tier: 'gold')
      expect(plan.metadata).to eq(trial_days: 14, tier: 'gold')
    end

    it 'reads without mutating when called with no args' do
      plan.metadata(trial_days: 14)
      expect(plan.metadata).to eq(trial_days: 14)
    end
  end

  describe 'amounts with no declared price' do
    subject(:plan) { described_class.new(:free) }

    it 'reports zero cents' do
      expect(plan.amount_cents).to eq(0)
    end

    it 'reports zero dollars' do
      expect(plan.amount).to eq(0.0)
    end

    it 'reports no stripe price id' do
      expect(plan.stripe_price_id).to be_nil
    end

    it 'reports no intervals' do
      expect(plan.intervals).to eq([])
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

    it 'is false when at least one interval has a non-zero price' do
      plan = described_class.new(:pro).tap do |p|
        p.price(0,  interval: :month)
        p.price(99, interval: :year)
      end
      expect(plan.free?).to be false
    end
  end

  describe 'limits accessor' do
    subject(:plan) do
      described_class.new(:pro).tap { |p| p.limit(:projects, 5) }
    end

    it 'returns a copy that cannot mutate internal state' do
      plan.limits[:projects] = 999
      expect(plan.limit(:projects)).to eq(5)
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

    it 'serializes prices per interval in cents' do
      expect(plan.to_h[:prices]).to eq(
        month: { amount_cents: 4900, stripe_price: 'price_x' }
      )
    end

    it 'defaults name to the capitalized key when none is set' do
      expect(described_class.new(:enterprise).to_h[:name]).to eq('Enterprise')
    end

    it 'serializes an undeclared description as nil' do
      expect(described_class.new(:basic).to_h[:description]).to be_nil
    end
  end
end
