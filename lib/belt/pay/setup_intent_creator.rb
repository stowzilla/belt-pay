# frozen_string_literal: true

module Belt
  module Pay
    # Creates a SetupIntent for securely collecting payment details on the frontend.
    class SetupIntentCreator
      Result = Struct.new(:client_secret, :pay_customer_id, keyword_init: true)

      attr_reader :customer

      def initialize(customer)
        @customer = customer
      end

      # @return [Result]
      def call
        # Ensure provider customer exists
        pay_customer_id = CustomerProvisioner.new(customer).call

        # Create setup intent via provider
        result = Belt::Pay.provider.create_setup_intent(pay_customer_id, customer_id: customer.id)

        Belt::Pay.log(:info, 'Belt::Pay::SetupIntentCreator: created',
                      customer_id: customer.id, pay_customer_id: pay_customer_id)

        Result.new(client_secret: result[:client_secret], pay_customer_id: pay_customer_id)
      end
    end
  end
end
