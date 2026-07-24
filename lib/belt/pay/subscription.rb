# frozen_string_literal: true

module Belt
  module Pay
    # Manages subscriptions — create, cancel, check status.
    module Subscription
      class << self
        # Create a subscription for a customer.
        # @param customer [Object] App model with Billable included
        # @param price_id [String] Provider price/plan ID
        # @param metadata [Hash]
        # @return [Hash] { subscription_id:, status:, current_period_end: }
        def create(customer, price_id:, metadata: {})
          CustomerProvisioner.new(customer).call

          result = Belt::Pay.provider.create_subscription(
            customer.pay_customer_id,
            price_id: price_id,
            metadata: metadata.merge(app_customer_id: customer.id)
          )

          # Record the transaction
          Transaction.record_subscription(
            customer_id: customer.id,
            subscription_id: result[:subscription_id],
            amount_cents: 0, # Amount comes from invoice.paid webhook
            metadata: metadata.merge(price_id: price_id)
          )

          Belt::Pay.log(:info, 'Belt::Pay::Subscription: created',
                        customer_id: customer.id, subscription_id: result[:subscription_id],
                        status: result[:status])

          result
        end

        # Cancel a subscription.
        # @param customer [Object] App model
        # @param immediately [Boolean]
        def cancel(customer, immediately: false)
          subscription_id = customer.pay_subscription_id
          raise Error, 'Customer has no active subscription' unless subscription_id

          Belt::Pay.provider.cancel_subscription(subscription_id, immediately: immediately)

          Belt::Pay.log(:info, 'Belt::Pay::Subscription: canceled',
                        customer_id: customer.id, subscription_id: subscription_id,
                        immediately: immediately)
        end

        # Check if a customer's subscription is active.
        # @param customer [Object] App model
        # @return [Boolean]
        def active?(customer)
          subscription_id = customer.pay_subscription_id
          return false unless subscription_id

          Belt::Pay.provider.subscription_active?(subscription_id)
        end
      end
    end
  end
end
