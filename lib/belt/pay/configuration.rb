# frozen_string_literal: true

module Belt
  module Pay
    class Configuration
      attr_accessor :provider, :secret_name, :webhook_secret_name,
                    :table_name_prefix, :logger, :test_mode

      def initialize
        @provider = :stripe
        @secret_name = ENV['BELT_PAY_SECRET_NAME']
        @webhook_secret_name = ENV['BELT_PAY_WEBHOOK_SECRET_NAME']
        @table_name_prefix = "#{ENV['APP_NAME']}-#{ENV['ENVIRONMENT']}"
        @logger = nil
        @test_mode = ENV['BELT_PAY_MODE'] != 'live'
      end

      def transactions_table_name
        "#{table_name_prefix}-pay-transactions"
      end
    end
  end
end
