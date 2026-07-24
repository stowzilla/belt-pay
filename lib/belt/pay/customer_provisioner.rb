# frozen_string_literal: true

module Belt
  module Pay
    # Ensures a payment provider customer exists for a given app customer.
    # Idempotent — safe to call multiple times.
    class CustomerProvisioner
      attr_reader :customer

      def initialize(customer)
        @customer = customer
      end

      # @return [String] The provider customer ID
      def call
        return customer.pay_customer_id if customer.pay_customer_id

        # Check for concurrent write (another request may have created one)
        fresh = customer.class.find(customer.id)
        if fresh&.pay_customer_id
          customer.pay_customer_id = fresh.pay_customer_id
          Belt::Pay.log(:info, 'Belt::Pay::CustomerProvisioner: found existing (concurrent write)',
                        customer_id: customer.id, pay_customer_id: fresh.pay_customer_id)
          return fresh.pay_customer_id
        end

        # Create via provider
        pay_customer_id = Belt::Pay.provider.create_customer(customer)

        customer.pay_customer_id = pay_customer_id
        unless customer.save(validate: false)
          raise Error, "Belt::Pay::CustomerProvisioner: failed to persist pay_customer_id=#{pay_customer_id}"
        end

        Belt::Pay.log(:info, 'Belt::Pay::CustomerProvisioner: created',
                      customer_id: customer.id, pay_customer_id: pay_customer_id)
        pay_customer_id
      end
    end
  end
end
