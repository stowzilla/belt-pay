# frozen_string_literal: true

require 'io/console'
require 'json'
require 'open3'
require 'optparse'
require 'shellwords'
require 'tempfile'
require 'aws-sdk-secretsmanager'
require 'stripe'
require 'belt/pay/webhook_handler'

module Belt
  module Pay
    class CLI
      class Error < StandardError; end

      COMMANDS = %w[secrets:setup secrets:show secrets:edit].freeze
      WEBHOOK_PATH = '/pay/webhooks'

      def self.start(args, input: $stdin, out: $stdout, err: $stderr)
        new(args, input: input, out: out, err: err).run
        0
      rescue Error, OptionParser::ParseError => e
        err.puts "Error: #{e.message}"
        err.puts "Run `belt tasks --grep pay` for available Belt Pay commands."
        1
      rescue Aws::Errors::ServiceError => e
        err.puts "AWS error: #{e.message}"
        1
      rescue ::Stripe::StripeError => e
        err.puts "Stripe error: #{e.message}"
        1
      end

      def initialize(args, input:, out:, err:)
        @args = args.dup
        @input = input
        @out = out
        @err = err
        @options = {}
      end

      def run
        command = @args.shift
        if command.nil? || %w[help --help -h].include?(command)
          @out.puts help
          return
        end

        raise Error, "unknown command #{command.inspect}" unless COMMANDS.include?(command)

        parse_options!
        resolve_context!

        case command
        when 'secrets:setup' then setup
        when 'secrets:show' then show
        when 'secrets:edit' then edit
        end
      end

      private

      def parse_options!
        parser.parse!(@args)
        @environment = @args.shift || ENV['BELT_ENV']
        raise Error, 'environment is required (for example, dev or prod)' if blank?(@environment)
        raise Error, "unexpected argument #{@args.first.inspect}" unless @args.empty?
      end

      def parser
        OptionParser.new do |opts|
          opts.banner = 'Usage: belt-pay secrets:setup|secrets:show|secrets:edit ENV [options]'

          opts.on('--app-name NAME', 'Override the detected Belt application name') do |value|
            @options[:app_name] = value
          end
          opts.on('--secret-name NAME', 'Override the Secrets Manager secret name') do |value|
            @options[:secret_name] = value
          end
          opts.on('--profile PROFILE', 'Override the AWS profile') do |value|
            @options[:profile] = value
          end
          opts.on('--region REGION', 'Override the AWS region') do |value|
            @options[:region] = value
          end
          opts.on('--webhook-url URL', 'Override the Stripe webhook endpoint URL') do |value|
            @options[:webhook_url] = value
          end
          opts.on('--webhook-events LIST', 'Comma-separated Stripe events for a new endpoint') do |value|
            @options[:webhook_events] = value
          end
          opts.on('-h', '--help', 'Show this help') do
            @out.puts help
            exit 0
          end
        end
      end

      def resolve_context!
        @root = find_project_root
        env_dir = File.join(@root, 'infrastructure', @environment)
        raise Error, "environment not found: #{env_dir}" unless Dir.exist?(env_dir)

        @app_name = @options[:app_name] || ENV['APP_NAME'] || detect_app_name(env_dir)
        raise Error, 'could not determine the application name; pass --app-name or set APP_NAME' if blank?(@app_name)

        @secret_name = @options[:secret_name] || ENV['BELT_PAY_SECRET_NAME'] ||
                       "#{@app_name}-#{@environment}-stripe"
        @profile = @options[:profile] || ENV['AWS_PROFILE'] || detect_profile(env_dir)
        @region = @options[:region] || ENV['AWS_REGION'] || ENV['AWS_DEFAULT_REGION'] || detect_region(env_dir)

        ENV['AWS_PROFILE'] = @profile unless blank?(@profile)
        @client = Aws::SecretsManager::Client.new(region: @region)
      end

      def setup
        response = fetch_secret
        original = parse_secret(response.secret_string)
        updated = original.dup

        secret_key = hidden_prompt('Stripe secret key [blank keeps existing]')
        updated['stripe_secret_key'] = secret_key unless blank?(secret_key)

        webhook_secret, replaced = webhook_secret_for(updated['stripe_secret_key'], original['stripe_webhook_secret'])
        updated['stripe_webhook_secret'] = webhook_secret unless blank?(webhook_secret)

        update_secret(response, original, updated)
        delete_replaced_endpoints(updated['stripe_secret_key'], replaced)
      end

      # Returns [signing_secret, endpoints_to_delete]. Offers to create the Stripe
      # webhook endpoint (Stripe only returns a signing secret at creation time);
      # otherwise prints Dashboard instructions and prompts for the secret.
      def webhook_secret_for(api_key, existing_secret)
        if blank?(api_key)
          @out.puts 'No Stripe secret key stored yet, so the webhook endpoint cannot be created for you.'
          return [manual_webhook_secret(nil), []]
        end

        mode = stripe_mode(api_key)
        url = webhook_url
        @out.puts "Stripe account mode: #{mode}"
        @out.puts "Webhook endpoint URL: #{url || '(unknown; run `belt apply` first or pass --webhook-url)'}"

        create = !url.nil? && confirm("Create the #{mode}-mode webhook endpoint in Stripe now?", default: blank?(existing_secret))
        return [manual_webhook_secret(url, mode: mode), []] unless create

        existing = stripe_endpoints(api_key).select { |endpoint| endpoint.url == url }
        if existing.any?
          ids = existing.map(&:id).join(', ')
          @out.puts "Stripe already has an endpoint for this URL (#{ids}). Stripe never re-sends a signing secret,"
          @out.puts 'so setup can only replace it with a new endpoint (the old secret stops working).'
          unless confirm('Replace it?', default: false)
            @out.puts "Reveal its signing secret at #{dashboard_url(mode, existing.first.id)}"
            return [hidden_prompt('Stripe webhook signing secret [blank keeps existing]'), []]
          end
        end

        endpoint = ::Stripe::WebhookEndpoint.create(
          { url: url, enabled_events: webhook_events, description: "Belt Pay (#{@app_name} #{@environment})" },
          { api_key: api_key }
        )
        @out.puts "Created #{mode}-mode webhook endpoint #{endpoint.id} for #{webhook_events.size} events."
        [endpoint.secret, existing.map(&:id)]
      end

      def manual_webhook_secret(url, mode: nil)
        @out.puts <<~STEPS

          To set up the webhook in the Stripe Dashboard#{" (#{mode} mode)" if mode}:
            1. Developers -> Webhooks -> Add destination (#{mode == 'live' ? 'https://dashboard.stripe.com/webhooks' : 'https://dashboard.stripe.com/test/webhooks'})
            2. Events from: Your account. API version: the default.
            3. Events: #{webhook_events.join(', ')}
            4. Destination type: Webhook endpoint
            5. URL: #{url || "your API base URL (`belt output #{@environment}` api_url) + #{WEBHOOK_PATH}"}
            6. Open the new endpoint -> Signing secret -> Reveal, and paste it below.
          Each endpoint (and test vs. live mode) has its own whsec_ secret. Do not use the
          one `stripe listen` prints; it only works for local forwarding.

        STEPS
        hidden_prompt('Stripe webhook signing secret [blank keeps existing]')
      end

      def delete_replaced_endpoints(api_key, ids)
        ids.each do |id|
          ::Stripe::WebhookEndpoint.delete(id, {}, { api_key: api_key })
          @out.puts "Deleted replaced webhook endpoint #{id}"
        end
      end

      def stripe_endpoints(api_key)
        ::Stripe::WebhookEndpoint.list({ limit: 100 }, { api_key: api_key }).auto_paging_each.to_a
      end

      def webhook_url
        return @webhook_url if defined?(@webhook_url)

        explicit = @options[:webhook_url] || ENV['BELT_PAY_WEBHOOK_URL']
        @webhook_url = if blank?(explicit)
                         api_url = terraform_output('api_url')
                         "#{api_url.chomp('/')}#{WEBHOOK_PATH}" unless blank?(api_url)
                       else
                         explicit.strip
                       end
      end

      def webhook_events
        list = @options[:webhook_events] || ENV['BELT_PAY_WEBHOOK_EVENTS']
        return Belt::Pay::WebhookHandler::EVENTS if blank?(list)

        list.split(',').map(&:strip).reject(&:empty?)
      end

      def terraform_output(name)
        env_dir = File.join(@root, 'infrastructure', @environment)
        stdout, _stderr, status = Open3.capture3('terraform', "-chdir=#{env_dir}", 'output', '-raw', name)
        stdout.strip if status.success?
      rescue SystemCallError
        nil
      end

      def stripe_mode(api_key)
        api_key.match?(/\A[sr]k_live_/) ? 'live' : 'test'
      end

      def dashboard_url(mode, endpoint_id)
        "https://dashboard.stripe.com/#{'test/' unless mode == 'live'}webhooks/#{endpoint_id}"
      end

      def confirm(question, default:)
        @out.print "#{question} #{default ? '[Y/n]' : '[y/N]'} "
        @out.flush
        answer = @input.gets
        @out.puts if answer.nil?
        return default if answer.nil? || answer.strip.empty?

        answer.strip.downcase.start_with?('y')
      end

      def show
        response = fetch_secret
        @out.puts JSON.pretty_generate(parse_secret(response.secret_string))
      end

      def edit
        response = fetch_secret
        original = parse_secret(response.secret_string)
        edited = edit_json(original)

        update_secret(response, original, edited)
      end

      def update_secret(response, original, updated)
        if updated == original
          @out.puts "Secret unchanged: #{@secret_name}"
          return
        end

        latest = fetch_secret
        if latest.version_id != response.version_id
          raise Error, "#{@secret_name} changed while it was open; reopen it and apply your edits again"
        end

        @client.put_secret_value(
          secret_id: @secret_name,
          secret_string: JSON.generate(updated)
        )
        @out.puts "Updated secret: #{@secret_name}"
      end

      def fetch_secret
        response = @client.get_secret_value(secret_id: @secret_name)
        raise Error, "#{@secret_name} is binary; belt-pay only supports JSON string secrets" if response.secret_string.nil?

        response
      end

      def parse_secret(value)
        parsed = JSON.parse(value)
        raise Error, "#{@secret_name} must contain a JSON object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError => e
        raise Error, "#{@secret_name} does not contain valid JSON: #{e.message}"
      end

      def hidden_prompt(label)
        @out.print "#{label}: "
        @out.flush
        value = if @input.respond_to?(:tty?) && @input.tty? && @input.respond_to?(:noecho)
                  @input.noecho { @input.gets }
                else
                  @input.gets
                end
        @out.puts
        raise Error, 'input ended before the Stripe secrets were read' if value.nil?

        value.chomp
      end

      def edit_json(secret)
        editor = ENV['VISUAL'] || ENV['EDITOR']
        raise Error, 'set $VISUAL or $EDITOR before running secrets:edit' if blank?(editor)

        Tempfile.create(["belt-pay-#{@environment}-", '.json']) do |file|
          File.chmod(0o600, file.path)
          file.write("#{JSON.pretty_generate(secret)}\n")
          file.flush

          success = system(*Shellwords.split(editor), file.path)
          raise Error, 'editor exited unsuccessfully; secret was not updated' unless success

          file.rewind
          parse_secret(file.read)
        end
      end

      def find_project_root
        dir = File.expand_path(Dir.pwd)
        loop do
          routes = [
            File.join(dir, 'config', 'routes.rb'),
            File.join(dir, 'config', 'routes.tf.rb'),
            File.join(dir, 'infrastructure', 'routes.tf.rb')
          ]
          return dir if routes.any? { |path| File.file?(path) }

          parent = File.dirname(dir)
          break if parent == dir

          dir = parent
        end

        raise Error, 'could not find a Belt application; run this command inside one'
      end

      def detect_app_name(env_dir)
        from_assignment(File.join(env_dir, 'terraform.tfvars'), 'app_name') ||
          from_variable_default(File.join(env_dir, 'variables.tf'), 'app_name') ||
          Dir.glob(File.join(@root, 'infrastructure', '*', 'terraform.tfvars')).sort.filter_map do |path|
            from_assignment(path, 'app_name')
          end.first ||
          Dir.glob(File.join(@root, 'infrastructure', '*', 'variables.tf')).sort.filter_map do |path|
            from_variable_default(path, 'app_name')
          end.first ||
          File.basename(@root)
      end

      def detect_profile(env_dir)
        path = File.join(env_dir, 'belt.rb')
        return unless File.file?(path)

        File.read(path)[/config\.aws_profile\s*=\s*['\"]([^'\"]+)['\"]/, 1]
      end

      def detect_region(env_dir)
        from_assignment(File.join(env_dir, 'terraform.tfvars'), 'aws_region') ||
          from_variable_default(File.join(env_dir, 'variables.tf'), 'aws_region') ||
          'us-east-1'
      end

      def from_assignment(path, key)
        return unless File.file?(path)

        File.read(path)[/^\s*#{Regexp.escape(key)}\s*=\s*['\"]([^'\"]+)['\"]/, 1]
      end

      def from_variable_default(path, key)
        return unless File.file?(path)

        block = File.read(path)[/variable\s+['\"]#{Regexp.escape(key)}['\"]\s*\{(.*?)\}/m, 1]
        block&.match(/^\s*default\s*=\s*['\"]([^'\"]+)['\"]/)&.captures&.first
      end

      def blank?(value)
        value.nil? || value.strip.empty?
      end

      def help
        <<~HELP
          Manage a Belt application's Stripe secret in AWS Secrets Manager.

          Usage:
            belt-pay secrets:setup ENV [options]
            belt-pay secrets:show ENV [options]
            belt-pay secrets:edit ENV [options]

          Commands:
            secrets:setup        Prompt without echo for the Stripe secret key, then create
                                 the webhook endpoint in Stripe and store its signing
                                 secret (or walk through creating it in the Dashboard)
            secrets:show         Print the decrypted JSON secret
            secrets:edit         Edit the secret with $VISUAL or $EDITOR

          Options:
            --app-name NAME      Override the detected application name
            --secret-name NAME   Override <app>-<environment>-stripe
            --profile PROFILE    Override the environment's AWS profile
            --region REGION      Override the detected AWS region
            --webhook-url URL    Override <terraform api_url>#{WEBHOOK_PATH}
            --webhook-events L   Comma-separated events (default: every event Belt Pay handles)
            -h, --help           Show this help

          Environment:
            BELT_ENV             Environment when ENV is omitted
            AWS_PROFILE          AWS profile (overrides infrastructure/ENV/belt.rb)
            AWS_REGION           AWS region (default: us-east-1)
            BELT_PAY_WEBHOOK_URL     Same as --webhook-url
            BELT_PAY_WEBHOOK_EVENTS  Same as --webhook-events
            VISUAL, EDITOR       Editor command for secrets:edit

          Examples:
            belt-pay secrets:setup dev
            belt-pay secrets:show dev
            belt-pay secrets:edit prod --profile my-prod-profile
            BELT_ENV=staging belt-pay secrets:setup

          Security:
            secrets:setup reads values without echo and sends them directly through the
            AWS SDK. secrets:show writes the complete secret to stdout. secrets:edit uses
            a mode-0600 temporary file, validates JSON, and removes the file afterward.
        HELP
      end
    end
  end
end
