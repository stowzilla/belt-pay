# frozen_string_literal: true

RSpec.describe Belt::Pay do
  describe '.configuration' do
    it 'returns a Configuration instance' do
      expect(described_class.configuration).to be_a(Belt::Pay::Configuration)
    end
  end

  describe '.configure' do
    it 'yields the configuration' do
      described_class.configure do |config|
        config.provider = :stripe
        config.table_name_prefix = 'test-app-dev'
      end

      expect(described_class.configuration.provider).to eq(:stripe)
      expect(described_class.configuration.table_name_prefix).to eq('test-app-dev')
    end
  end

  describe '.provider' do
    it 'returns Stripe provider by default' do
      expect(described_class.provider).to be_a(Belt::Pay::Providers::Stripe)
    end

    it 'raises for unknown provider' do
      described_class.configure { |c| c.provider = :paypal }
      expect { described_class.provider }.to raise_error(Belt::Pay::ConfigurationError, /Unknown provider/)
    end
  end

  describe '.reset_configuration!' do
    it 'resets to defaults' do
      described_class.configure { |c| c.provider = :stripe }
      described_class.reset_configuration!
      expect(described_class.configuration.provider).to eq(:stripe)
    end
  end
end
