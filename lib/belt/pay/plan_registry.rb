# frozen_string_literal: true

require_relative 'plan'

module Belt
  module Pay
    # Registry of declared subscription plans.
    #
    # Plans are declared once at boot (convention over configuration) and looked
    # up by their symbolic key everywhere else. This mirrors how popular Ruby
    # billing gems keep plan definitions in code rather than scattered config.
    #
    # @example Declaring plans
    #   Belt::Pay.plans do
    #     plan :free do
    #       name  'Free'
    #       limit :projects, 1
    #     end
    #
    #     plan :pro do
    #       name 'Pro'
    #       featured
    #       price 49,  interval: :month, stripe_price: ENV['STRIPE_PRO_MONTH']
    #       price 490, interval: :year,  stripe_price: ENV['STRIPE_PRO_YEAR']
    #       limit :projects, :unlimited
    #     end
    #   end
    #
    # @example Looking plans up
    #   Belt::Pay.plan(:pro)                  # => #<Belt::Pay::Plan key=:pro>
    #   Belt::Pay.plans.all                   # => [free, pro, ...]
    #   Belt::Pay.plan_for_price('price_xxx') # => the plan owning that Stripe price
    #
    class PlanRegistry
      def initialize
        @plans = {}
      end

      # DSL entry: declare a plan by key with a config block.
      def plan(key, &block)
        p = @plans[key.to_sym] || Plan.new(key)
        p.instance_eval(&block) if block
        @plans[key.to_sym] = p
        p
      end

      # Look up a plan by key. Returns nil if not declared.
      def find(key)
        return nil if key.nil?

        @plans[key.to_sym]
      end
      alias [] find

      # Look up a plan by key, raising if it isn't declared.
      def find!(key)
        find(key) || raise(Error, "Unknown plan: #{key.inspect}. " \
                                  "Declared plans: #{keys.map(&:inspect).join(', ')}")
      end

      # Find the plan that owns a given Stripe price ID (across all intervals).
      def find_by_stripe_price(price_id)
        return nil if price_id.nil?

        @plans.values.find do |pl|
          pl.intervals.any? { |i| pl.stripe_price_id(interval: i) == price_id }
        end
      end

      # All declared plans, in declaration order.
      def all
        @plans.values
      end

      # All declared plan keys.
      def keys
        @plans.keys
      end

      # Only the paid plans (have at least one non-zero price).
      def paid
        @plans.values.reject(&:free?)
      end

      # The single plan marked `featured` (or nil).
      def featured
        @plans.values.find(&:featured?)
      end

      def empty?
        @plans.empty?
      end

      # Serialize every plan for API/frontend consumption.
      def to_a
        all.map(&:to_h)
      end

      # Wipe all plans (useful for tests).
      def reset!
        @plans = {}
      end
    end
  end
end
