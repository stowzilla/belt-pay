# frozen_string_literal: true

RSpec.describe Belt::Pay::PlanRegistry do
  subject(:registry) { described_class.new }

  describe 'declaring plans via the DSL' do
    before do
      registry.plan(:free) do
        name 'Free'
        limit :projects, 1
      end

      registry.plan(:pro) do
        name 'Pro'
        featured
        price 49,  interval: :month, stripe_price: 'price_pro_month'
        price 490, interval: :year,  stripe_price: 'price_pro_year'
        limit :projects, :unlimited
      end
    end

    it 'finds a plan by key' do
      expect(registry.find(:pro).name).to eq('Pro')
      expect(registry[:free].name).to eq('Free')
    end

    it 'returns nil for an unknown key' do
      expect(registry.find(:enterprise)).to be_nil
    end

    it 'raises on find! for an unknown key' do
      expect { registry.find!(:enterprise) }
        .to raise_error(Belt::Pay::Error, /Unknown plan/)
    end

    it 'lists all plans in declaration order' do
      expect(registry.all.map(&:key)).to eq(%i[free pro])
    end

    it 'lists only paid plans' do
      expect(registry.paid.map(&:key)).to eq(%i[pro])
    end

    it 'exposes the featured plan' do
      expect(registry.featured.key).to eq(:pro)
    end

    it 'finds a plan by its Stripe price id (any interval)' do
      expect(registry.find_by_stripe_price('price_pro_year').key).to eq(:pro)
      expect(registry.find_by_stripe_price('price_pro_month').key).to eq(:pro)
    end

    it 'returns nil finding by an unknown price id' do
      expect(registry.find_by_stripe_price('price_nope')).to be_nil
    end

    it 'serializes all plans to an array of hashes' do
      arr = registry.to_a
      expect(arr.map { |h| h[:key] }).to eq(%w[free pro])
    end

    it 'merges config when the same plan key is declared twice' do
      registry.plan(:pro) { description 'Now with more' }
      expect(registry.find(:pro).name).to eq('Pro')            # preserved
      expect(registry.find(:pro).description).to eq('Now with more') # added
    end
  end

  describe '#reset!' do
    it 'clears all plans' do
      registry.plan(:free) { name 'Free' }
      registry.reset!
      expect(registry.empty?).to be true
    end
  end
end

RSpec.describe 'Belt::Pay plan module API' do
  before do
    Belt::Pay.plans do
      plan(:free) { name 'Free'; limit :projects, 1 }
      plan(:pro) do
        name 'Pro'
        price 49, interval: :month, stripe_price: 'price_pro_month'
      end
    end
  end

  it 'exposes plans through Belt::Pay.plans' do
    expect(Belt::Pay.plans.keys).to eq(%i[free pro])
  end

  it 'looks up a single plan through Belt::Pay.plan' do
    expect(Belt::Pay.plan(:pro).name).to eq('Pro')
  end

  it 'resolves a plan from a Stripe price id' do
    expect(Belt::Pay.plan_for_price('price_pro_month').key).to eq(:pro)
  end
end
