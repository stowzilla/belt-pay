# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require 'belt/pay/cli'

RSpec.describe Belt::Pay::CLI, 'secrets:setup with a restricted stored key' do
  let(:root) { Dir.mktmpdir('belt-pay-cli') }
  let(:client) { instance_double(Aws::SecretsManager::Client) }
  let(:secret) { Struct.new(:secret_string, :version_id).new('{}', 'v1') }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:url) { 'https://api.example.com/pay/webhooks' }
  let(:stored) { [] }
  let(:denied) { ::Stripe::PermissionError.new('does not have the required permissions') }

  before do
    FileUtils.mkdir_p(File.join(root, 'config'))
    FileUtils.mkdir_p(File.join(root, 'infrastructure', 'prod'))
    File.write(File.join(root, 'config', 'routes.rb'), '')
    allow(Aws::SecretsManager::Client).to receive(:new).and_return(client)
    allow(client).to receive(:get_secret_value).and_return(secret)
    allow(client).to receive(:put_secret_value) { |args| stored << JSON.parse(args[:secret_string]) }
  end

  after { FileUtils.remove_entry(root) }

  def run_setup(*answers)
    Dir.chdir(root) do
      described_class.start(['secrets:setup', 'prod', '--app-name', 'app', '--webhook-url', url],
                            input: StringIO.new(answers.map { |a| "#{a}\n" }.join), out: out, err: err)
    end
  end

  def endpoints(list = [])
    double(auto_paging_each: list)
  end

  it 'manages the endpoint with a one-time key and stores only the restricted key' do
    allow(Stripe::WebhookEndpoint).to receive(:list) do |_params, opts|
      raise denied if opts[:api_key] == 'rk_live_runtime'

      endpoints
    end
    expect(Stripe::WebhookEndpoint).to receive(:create)
      .with(hash_including(url: url), { api_key: 'sk_live_admin' })
      .and_return(double(id: 'we_1', secret: 'whsec_new'))

    expect(run_setup('rk_live_runtime', 'y', 'sk_live_admin')).to eq(0)
    expect(stored.last).to eq('stripe_secret_key' => 'rk_live_runtime', 'stripe_webhook_secret' => 'whsec_new')
    expect(out.string).to include('not stored')
  end

  it 'deletes a replaced endpoint with the one-time key' do
    allow(Stripe::WebhookEndpoint).to receive(:list) do |_params, opts|
      raise denied if opts[:api_key] == 'rk_live_runtime'

      endpoints([double(id: 'we_old', url: url)])
    end
    allow(Stripe::WebhookEndpoint).to receive(:create).and_return(double(id: 'we_new', secret: 'whsec_new'))
    expect(Stripe::WebhookEndpoint).to receive(:delete).with('we_old', {}, { api_key: 'sk_live_admin' })

    expect(run_setup('rk_live_runtime', 'y', 'sk_live_admin', 'y')).to eq(0)
  end

  it 'falls back to the Dashboard steps and still saves the stored key when no one-time key is given' do
    allow(Stripe::WebhookEndpoint).to receive(:list).and_raise(denied)
    expect(Stripe::WebhookEndpoint).not_to receive(:create)

    expect(run_setup('rk_live_runtime', 'y', '', 'whsec_manual')).to eq(0)
    expect(out.string).to include('Developers -> Webhooks')
    expect(stored.last).to eq('stripe_secret_key' => 'rk_live_runtime', 'stripe_webhook_secret' => 'whsec_manual')
  end

  it 'refuses a one-time key from the other Stripe mode' do
    allow(Stripe::WebhookEndpoint).to receive(:list).and_raise(denied)

    expect(run_setup('rk_live_runtime', 'y', 'sk_test_admin', '')).to eq(0)
    expect(out.string).to include('test-mode key; the stored key is live mode')
    expect(stored.last).to eq('stripe_secret_key' => 'rk_live_runtime')
  end

  it 'falls back to the Dashboard steps when the one-time key is refused too' do
    allow(Stripe::WebhookEndpoint).to receive(:list).and_raise(denied)

    expect(run_setup('rk_live_runtime', 'y', 'rk_live_other', '')).to eq(0)
    expect(out.string).to include('Stripe refused that key too')
    expect(err.string).to be_empty
  end
end
