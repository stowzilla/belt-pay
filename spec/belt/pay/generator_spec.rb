# frozen_string_literal: true

RSpec.describe Belt::Pay::Generators::PayGenerator do
  # Generator specs use a temporary directory to verify file creation
  # without touching real project files.

  let(:tmpdir) { Dir.mktmpdir('belt-pay-gen-') }

  before do
    # Create minimal project structure
    FileUtils.mkdir_p("#{tmpdir}/infrastructure")
    FileUtils.mkdir_p("#{tmpdir}/config")
    FileUtils.mkdir_p("#{tmpdir}/lambda")

    File.write("#{tmpdir}/infrastructure/routes.tf.rb", <<~ROUTES)
      Belt.application.routes.draw do
        namespace :api do
          resources :users, only: [:index, :show]
        end
      end
    ROUTES

    File.write("#{tmpdir}/infrastructure/schema.tf.rb", <<~SCHEMA)
      Belt.application.schema.define do
        model :user do
          partition_key :id, :string
        end
      end
    SCHEMA
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe '.run' do
    it 'creates terraform module files' do
      Dir.chdir(tmpdir) { described_class.run([]) }
      expect(File.exist?("#{tmpdir}/infrastructure/modules/pay/main.tf")).to be true
      expect(File.exist?("#{tmpdir}/infrastructure/modules/pay/variables.tf")).to be true
      expect(File.exist?("#{tmpdir}/infrastructure/modules/pay/outputs.tf")).to be true
    end

    it 'creates lambda config' do
      Dir.chdir(tmpdir) { described_class.run([]) }
      expect(File.exist?("#{tmpdir}/config/lambda/pay_webhooks.yml")).to be true
    end

    it 'creates lambda entry point' do
      Dir.chdir(tmpdir) { described_class.run([]) }
      expect(File.exist?("#{tmpdir}/lambda/pay_webhooks.rb")).to be true
    end

    it 'injects schema' do
      Dir.chdir(tmpdir) { described_class.run([]) }
      schema = File.read("#{tmpdir}/infrastructure/schema.tf.rb")
      expect(schema).to include('pay_transaction')
      expect(schema).to include('CustomerIndex')
      expect(schema).to include('ProviderSessionIndex')
    end

    it 'injects webhook route' do
      Dir.chdir(tmpdir) { described_class.run([]) }
      routes = File.read("#{tmpdir}/infrastructure/routes.tf.rb")
      expect(routes).to include('pay/webhooks')
    end
  end

  describe '.destroy' do
    it 'removes generated files' do
      Dir.chdir(tmpdir) do
        described_class.run([])
        described_class.destroy([])
      end

      expect(Dir.exist?("#{tmpdir}/infrastructure/modules/pay")).to be false
      expect(File.exist?("#{tmpdir}/config/lambda/pay_webhooks.yml")).to be false
      expect(File.exist?("#{tmpdir}/lambda/pay_webhooks.rb")).to be false
    end
  end
end
