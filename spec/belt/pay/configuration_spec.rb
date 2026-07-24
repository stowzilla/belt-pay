# frozen_string_literal: true

RSpec.describe Belt::Pay::Configuration do
  subject(:config) { described_class.new }

  describe '#initialize' do
    it 'defaults provider to :stripe' do
      expect(config.provider).to eq(:stripe)
    end

    it 'defaults test_mode to true when BELT_PAY_MODE is not live' do
      expect(config.test_mode).to be true
    end

    it 'reads secret_name from environment' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('BELT_PAY_SECRET_NAME').and_return('my-secret')
      new_config = described_class.new
      expect(new_config.secret_name).to eq('my-secret')
    end
  end

  describe '#transactions_table_name' do
    it 'builds table name from prefix' do
      config.table_name_prefix = 'myapp-prod'
      expect(config.transactions_table_name).to eq('myapp-prod-pay-transactions')
    end
  end
end
