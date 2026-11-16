# frozen_string_literal: true

module Belt
  module Pay
    class Configuration
      attr_accessor :provider, :secret_name, :webhook_secret_name,
                    :table_name_prefix, :logger, :test_mode, :customer_class

      def initialize
        @provider = :stripe
        @secret_name = ENV['BELT_PAY_SECRET_NAME']
        @webhook_secret_name = ENV['BELT_PAY_WEBHOOK_SECRET_NAME']
        @table_name_prefix = "#{ENV['APP_NAME']}-#{ENV['ENVIRONMENT']}"
        @logger = nil
        @test_mode = ENV['BELT_PAY_MODE'] != 'live'
        @customer_class = nil
      end

      # The app model that includes Belt::Pay::Billable, as set in `customer_class`
      # (the class, or its name as a String so it need not be loaded yet). The
      # webhook finds customers through it to keep `pay_plan` in step with the
      # subscription. Nil when not configured.
      # @return [Class, nil]
      def customer_model
        return nil if customer_class.nil?

        customer_class.is_a?(String) ? Object.const_get(customer_class) : customer_class
      end

      def transactions_table_name
        "#{table_name_prefix}-pay-transactions"
      end
    end
  end
end
