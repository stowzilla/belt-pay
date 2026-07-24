# frozen_string_literal: true

module Belt
  module Pay
    # Attaches a payment method to a customer's provider account and sets it as default.
    class PaymentMethodAttacher
      Result = Struct.new(:pay_customer_id, :payment_method_id, keyword_init: true)

      attr_reader :customer, :payment_method_id

      def initialize(customer, payment_method_id)
        @customer = customer
        @payment_method_id = payment_method_id
      end

      # @return [Result]
      def call
        # Ensure provider customer exists
        CustomerProvisioner.new(customer).call

        # Attach via provider
        Belt::Pay.provider.attach_payment_method(customer.pay_customer_id, payment_method_id)

        # Persist the payment method ID
        customer.pay_payment_method_id = payment_method_id
        unless customer.save(validate: false)
          raise Error, "Belt::Pay::PaymentMethodAttacher: failed to persist payment_method_id=#{payment_method_id}"
        end

        Belt::Pay.log(:info, 'Belt::Pay::PaymentMethodAttacher: completed',
                      customer_id: customer.id, pay_customer_id: customer.pay_customer_id,
                      payment_method_id: payment_method_id)

        Result.new(pay_customer_id: customer.pay_customer_id, payment_method_id: payment_method_id)
      end
    end
  end
end
