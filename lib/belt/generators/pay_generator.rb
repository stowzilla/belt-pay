# frozen_string_literal: true

require 'fileutils'
require 'erb'

module Belt
  module Generators
    class PayGenerator
      TEMPLATE_DIR = File.expand_path('../pay/templates', __dir__)

      def self.description
        'Install payments and subscriptions (Stripe)'
      end

      def self.run(args)
        if args.include?('--help') || args.include?('-h')
          print_help
          return
        end

        new(args).generate
      end

      def self.destroy(args)
        new(args).destroy
      end

      def self.print_help
        puts <<~HELP
          Install payment and subscription infrastructure for your Belt app.

          Usage: belt generate pay [options]

          Options:
            --controllers         Generate controller overrides (to customize webhook behavior)
            --force               Overwrite existing files

          What gets created:
            infrastructure/modules/pay/              Terraform module (Secrets Manager, IAM)
            config/lambda/pay_webhooks.yml           Lambda configuration (timeout, memory, env)
            lambda/pay_webhooks.rb                   Lambda entry point for Stripe webhooks
            infrastructure/schema.tf.rb              Updated with pay_transactions table

          What stays in the gem (no generation needed):
            Belt::Pay::Transaction                   Transaction audit log model
            Belt::Pay::Billable                      Concern for your Customer model
            Belt::Pay.create_checkout(...)           Create checkout sessions
            Belt::Pay.subscribe(...)                 Manage subscriptions
            Belt::Pay.billing_portal(...)            Customer self-service portal
            Belt::Pay::Controllers::WebhooksController  Default webhook handler

          To override the webhook controller:
            belt g pay --controllers

          After generation:
            1. Add module reference to your environment's main.tf
            2. Create Stripe keys in Secrets Manager (or via Terraform)
            3. Include Belt::Pay::Billable in your Customer/User model
            4. Deploy: belt apply <env>
            5. Configure Stripe webhook URL: https://<api-domain>/pay/webhooks

          Examples:
            belt g pay                     # Infrastructure only (use gem defaults)
            belt g pay --controllers       # Also generate controller overrides
            belt d pay
        HELP
      end

      def initialize(args)
        @force = args.include?('--force')
        @with_controllers = args.include?('--controllers')
        @app_name = detect_namespace
      end

      def generate
        generate_terraform_module
        generate_lambda_config
        generate_lambda_entry_point
        generate_controllers if @with_controllers
        inject_schema
        inject_routes
        print_success
      end

      def destroy
        remove_terraform_module
        remove_lambda_config
        remove_lambda_entry_point
        remove_controllers
        remove_schema
        remove_routes
        puts "\n✓ Pay removed!"
        puts "  Don't forget to remove the module reference from your environment main.tf files."
      end

      private

      def detect_namespace
        routes_file = find_routes_file_path
        if routes_file && File.exist?(routes_file)
          match = File.read(routes_file).match(/namespace :(\w+)/)
          return match[1] if match
        end
        File.basename(Dir.pwd)
      end

      def find_routes_file_path
        candidates = ['config/routes.tf.rb', 'infrastructure/routes.tf.rb']
        candidates.find { |f| File.exist?(f) }
      end

      # ---- Generate ----

      def generate_terraform_module
        module_dir = 'infrastructure/modules/pay'

        if Dir.exist?(module_dir) && !@force
          puts "  skip    #{module_dir}/ (already exists, use --force to overwrite)"
          return
        end

        FileUtils.mkdir_p(module_dir)

        write_template('terraform/main.tf.erb', "#{module_dir}/main.tf")
        write_template('terraform/variables.tf.erb', "#{module_dir}/variables.tf")
        write_template('terraform/outputs.tf.erb', "#{module_dir}/outputs.tf")

        puts "  create  #{module_dir}/main.tf"
        puts "  create  #{module_dir}/variables.tf"
        puts "  create  #{module_dir}/outputs.tf"
      end

      def generate_lambda_config
        config_dir = 'config/lambda'
        dest = "#{config_dir}/pay_webhooks.yml"

        if File.exist?(dest) && !@force
          puts "  skip    #{dest} (already exists)"
          return
        end

        FileUtils.mkdir_p(config_dir)
        write_template('config/pay_webhooks.yml.erb', dest)
        puts "  create  #{dest}"
      end

      def generate_lambda_entry_point
        dest = 'lambda/pay_webhooks.rb'

        if File.exist?(dest) && !@force
          puts "  skip    #{dest} (already exists)"
          return
        end

        write_template('lambda/pay_webhooks.rb.erb', dest)
        puts "  create  #{dest}"
      end

      def generate_controllers
        controller_dir = "lambda/controllers/#{@app_name}"
        FileUtils.mkdir_p(controller_dir)

        dest = "#{controller_dir}/pay_webhooks_controller.rb"
        if File.exist?(dest) && !@force
          puts "  skip    #{dest} (already exists)"
        else
          write_template('controllers/pay_webhooks_controller.rb.erb', dest)
          puts "  create  #{dest}"
        end
      end

      def inject_schema
        schema_file = find_schema_file_path
        return unless schema_file && File.exist?(schema_file)

        content = File.read(schema_file)
        return if content.include?('pay_transactions') || content.include?('pay-transactions')

        # Add transactions table to schema
        schema_block = <<~SCHEMA

  model :pay_transaction do
    partition_key :id, :string
    global_secondary_index :CustomerIndex, partition_key: :customer_id
    global_secondary_index :ProviderSessionIndex, partition_key: :provider_session_id
  end
        SCHEMA

        # Insert before the closing `end` of the schema.define block
        if content.match?(/^end\s*\z/m)
          content.sub!(/^end\s*\z/m, "#{schema_block}end\n")
        else
          content << "\n#{schema_block}"
        end

        File.write(schema_file, content)
        puts "  update  #{schema_file} (added pay_transactions table)"
      end

      def inject_routes
        routes_file = find_routes_file_path
        return unless routes_file && File.exist?(routes_file)

        content = File.read(routes_file)
        return if content.include?('pay_webhooks') || content.include?('pay/webhooks')

        # Add webhook route to the namespace
        namespace_pattern = /^(\s*)namespace :#{Regexp.escape(@app_name)}\b[^\n]*do\s*\n(.*?)^\1end/m
        if content.match?(namespace_pattern)
          webhook_route = "    post \"pay/webhooks\", controller: :pay_webhooks, action: :webhook, auth: :none"
          content.sub!(namespace_pattern) do |match|
            indent = ::Regexp.last_match(1)
            match.sub(/^(#{indent})end\z/m, "#{webhook_route}\n#{indent}end")
          end
        end

        File.write(routes_file, content)
        puts "  update  #{routes_file} (added pay webhook route)"
      end

      # ---- Destroy ----

      def remove_terraform_module
        module_dir = 'infrastructure/modules/pay'
        if Dir.exist?(module_dir)
          FileUtils.rm_rf(module_dir)
          puts "  remove  #{module_dir}/"
        end
      end

      def remove_lambda_config
        path = 'config/lambda/pay_webhooks.yml'
        if File.exist?(path)
          File.delete(path)
          puts "  remove  #{path}"
        end
      end

      def remove_lambda_entry_point
        path = 'lambda/pay_webhooks.rb'
        if File.exist?(path)
          File.delete(path)
          puts "  remove  #{path}"
        end
      end

      def remove_controllers
        path = "lambda/controllers/#{@app_name}/pay_webhooks_controller.rb"
        if File.exist?(path)
          File.delete(path)
          puts "  remove  #{path}"
        end
      end

      def remove_schema
        schema_file = find_schema_file_path
        return unless schema_file && File.exist?(schema_file)

        content = File.read(schema_file)
        original = content.dup

        content.gsub!(/\n\s*model :pay_transaction do.*?end\n/m, '')

        if content != original
          File.write(schema_file, content)
          puts "  update  #{schema_file} (removed pay_transactions table)"
        end
      end

      def remove_routes
        routes_file = find_routes_file_path
        return unless routes_file && File.exist?(routes_file)

        content = File.read(routes_file)
        original = content.dup

        content.gsub!(/^\s*post "pay\/webhooks".*\n/, '')

        if content != original
          File.write(routes_file, content)
          puts "  update  #{routes_file}"
        end
      end

      def find_schema_file_path
        candidates = ['infrastructure/schema.tf.rb', 'config/schema.tf.rb']
        candidates.find { |f| File.exist?(f) }
      end

      def write_template(template_name, dest_path)
        template_path = File.join(TEMPLATE_DIR, template_name)
        FileUtils.mkdir_p(File.dirname(dest_path))
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest_path, content)
      end

      def print_success
        puts <<~SUCCESS

          ✓ Payments installed!

          Next steps:
            1. Add the module to your environment's main.tf:

               module "pay" {
                 source      = "../modules/pay"
                 app_name    = var.app_name
                 environment = var.environment
               }

            2. Include Belt::Pay::Billable in your Customer/User model:

               class Customer < ActiveItem::Base
                 include Belt::Pay::Billable
                 # ...
               end

            3. Create your Stripe API keys in Secrets Manager:
               Secret name: <app_name>-<env>-stripe
               Keys: stripe_secret_key, stripe_webhook_secret

            4. Deploy:
               belt apply <env>

            5. Configure Stripe webhook endpoint:
               URL: https://<your-api-domain>/pay/webhooks
               Events: checkout.session.completed, checkout.session.expired,
                       invoice.paid, invoice.payment_failed,
                       customer.subscription.deleted, customer.subscription.updated

          Quick Usage:
            # Create a checkout session
            Belt::Pay.create_checkout(customer,
              line_items: [{ price: 'price_xxx', quantity: 1 }],
              mode: 'subscription',
              success_url: 'https://app.example.com/success',
              cancel_url: 'https://app.example.com/cancel')

            # Subscribe directly (if payment method already attached)
            customer.subscribe!(price_id: 'price_xxx')

            # Check subscription status
            customer.active_subscription?  # => true

            # Customer self-service
            customer.billing_portal_url(return_url: 'https://app.example.com/settings')

        SUCCESS
      end
    end
  end
end
