# frozen_string_literal: true

require 'json'
require 'optparse'
require 'shellwords'
require 'tempfile'
require 'aws-sdk-secretsmanager'

module Belt
  module Pay
    class CLI
      class Error < StandardError; end

      COMMANDS = %w[secrets:show secrets:edit].freeze

      def self.start(args, out: $stdout, err: $stderr)
        new(args, out: out, err: err).run
        0
      rescue Error, OptionParser::ParseError => e
        err.puts "Error: #{e.message}"
        err.puts "Run `belt-pay --help` for usage."
        1
      rescue Aws::Errors::ServiceError => e
        err.puts "AWS error: #{e.message}"
        1
      end

      def initialize(args, out:, err:)
        @args = args.dup
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

        command == 'secrets:show' ? show : edit
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
          opts.banner = 'Usage: belt-pay secrets:show|secrets:edit ENV [options]'

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

        @app_name = @options[:app_name] || detect_app_name(env_dir)
        raise Error, 'could not determine the application name; pass --app-name' if blank?(@app_name)

        @secret_name = @options[:secret_name] || "#{@app_name}-#{@environment}-stripe"
        @profile = @options[:profile] || ENV['AWS_PROFILE'] || detect_profile(env_dir)
        @region = @options[:region] || ENV['AWS_REGION'] || ENV['AWS_DEFAULT_REGION'] || detect_region(env_dir)

        ENV['AWS_PROFILE'] = @profile unless blank?(@profile)
        @client = Aws::SecretsManager::Client.new(region: @region)
      end

      def show
        response = fetch_secret
        @out.puts JSON.pretty_generate(parse_secret(response.secret_string))
      end

      def edit
        response = fetch_secret
        original = parse_secret(response.secret_string)
        edited = edit_json(original)

        if edited == original
          @out.puts "Secret unchanged: #{@secret_name}"
          return
        end

        latest = fetch_secret
        if latest.version_id != response.version_id
          raise Error, "#{@secret_name} changed while it was open; reopen it and apply your edits again"
        end

        @client.put_secret_value(
          secret_id: @secret_name,
          secret_string: JSON.generate(edited)
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
            belt-pay secrets:show ENV [options]
            belt-pay secrets:edit ENV [options]

          Commands:
            secrets:show         Print the decrypted JSON secret
            secrets:edit         Edit the secret with $VISUAL or $EDITOR

          Options:
            --app-name NAME      Override the detected application name
            --secret-name NAME   Override <app>-<environment>-stripe
            --profile PROFILE    Override the environment's AWS profile
            --region REGION      Override the detected AWS region
            -h, --help           Show this help

          Environment:
            BELT_ENV             Environment when ENV is omitted
            AWS_PROFILE          AWS profile (overrides infrastructure/ENV/belt.rb)
            AWS_REGION           AWS region (default: us-east-1)
            VISUAL, EDITOR       Editor command for secrets:edit

          Examples:
            belt-pay secrets:show dev
            belt-pay secrets:edit prod --profile my-prod-profile
            BELT_ENV=staging EDITOR="code --wait" belt-pay secrets:edit

          Security:
            secrets:show writes the complete secret to stdout. secrets:edit uses a
            mode-0600 temporary file, validates JSON, and removes the file afterward.
        HELP
      end
    end
  end
end
