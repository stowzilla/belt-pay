# frozen_string_literal: true

module Belt
  module Pay
    # A single subscription plan definition.
    #
    # Plans are declared once (convention over configuration) via `Belt::Pay.plans`
    # and looked up by their symbolic key. A plan bundles the human-facing marketing
    # copy (name, description, price), the Stripe price IDs for each billing interval,
    # and a set of named limits that the rest of your app can gate features on.
    #
    # @example
    #   Belt::Pay.plans do
    #     plan :free do
    #       name  'Free'
    #       price 0
    #       limit :projects, 1
    #       limit :seats,    3
    #     end
    #
    #     plan :pro do
    #       name        'Pro'
    #       description 'For growing teams'
    #       price       49, interval: :month, stripe_price: 'price_month_xxx'
    #       price       490, interval: :year, stripe_price: 'price_year_xxx'
    #       limit :projects, 25
    #       limit :seats,    :unlimited
    #       feature :sso
    #     end
    #   end
    #
    class Plan
      # Sentinel used for limits that have no ceiling.
      UNLIMITED = :unlimited

      attr_reader :key

      def initialize(key)
        @key         = key.to_sym
        @name        = key.to_s.capitalize
        @description = nil
        @featured    = false
        @prices      = {} # interval => { amount_cents:, stripe_price: }
        @limits      = {} # name => Integer | :unlimited
        @features    = [] # list of symbolic feature flags
        @metadata    = {}
      end

      # --- DSL setters (called inside `plan :key do ... end`) ---

      # Human-facing plan name. Reader when called with no args.
      def name(value = nil)
        return @name if value.nil?

        @name = value
      end

      # Marketing description. Reader when called with no args.
      def description(value = nil)
        return @description if value.nil?

        @description = value
      end

      # Mark this plan as the "most popular" / highlighted plan.
      def featured(value = true)
        @featured = value
      end

      # Declare a price for a billing interval.
      #
      # @param amount [Numeric] Price in whole currency units (e.g. dollars). Stored as cents.
      # @param interval [Symbol] :month | :year | :once (default :month)
      # @param stripe_price [String, nil] The Stripe price ID backing this amount.
      def price(amount, interval: :month, stripe_price: nil)
        @prices[interval.to_sym] = {
          amount_cents: (amount.to_f * 100).round,
          stripe_price: stripe_price
        }
      end

      # Declare a boolean feature this plan unlocks (e.g. :sso, :audit_logs).
      def feature(*names)
        @features.concat(names.map(&:to_sym))
      end

      # Arbitrary free-form metadata carried onto Stripe subscriptions.
      def metadata(hash = nil)
        return @metadata if hash.nil?

        @metadata.merge!(hash)
      end

      # --- Query API (used by the rest of your app) ---

      def featured?
        @featured
      end

      # The Stripe price ID for a given interval (defaults to :month, falls back
      # to the only price if the plan is single-interval).
      def stripe_price_id(interval: :month)
        entry = @prices[interval.to_sym] || @prices.values.first
        entry && entry[:stripe_price]
      end

      # Price in cents for a given interval.
      def amount_cents(interval: :month)
        entry = @prices[interval.to_sym] || @prices.values.first
        entry ? entry[:amount_cents] : 0
      end

      # Price in whole currency units (e.g. dollars) for a given interval.
      def amount(interval: :month)
        amount_cents(interval: interval) / 100.0
      end

      # Intervals this plan is priced for.
      def intervals
        @prices.keys
      end

      # Is this a free plan (no paid intervals)?
      def free?
        @prices.empty? || @prices.values.all? { |p| p[:amount_cents].zero? }
      end

      # Declare (2-arg form) or read (1-arg form) a named limit.
      # Use `:unlimited` for no ceiling.
      #
      # @example declare
      #   limit :projects, 25
      #   limit :seats, :unlimited
      # @example read
      #   plan.limit(:projects) # => 25
      #
      # @param name [Symbol] Limit name (e.g. :projects, :seats)
      # @param value [Integer, Symbol] Ceiling, or :unlimited (setter form only)
      # @return [Integer, Symbol, nil] The limit when reading; nil if undeclared.
      def limit(name, *value)
        if value.empty?
          @limits[name.to_sym]
        else
          v = value.first
          @limits[name.to_sym] = v == UNLIMITED ? UNLIMITED : Integer(v)
        end
      end

      # Is a given usage count allowed under this plan's limit?
      #
      # @param name [Symbol] Limit name
      # @param usage [Integer] Current usage count
      # @return [Boolean] true if under (or at) the limit, or unlimited/undeclared
      def allows?(name, usage)
        ceiling = @limits[name.to_sym]
        return true if ceiling.nil? || ceiling == UNLIMITED

        usage < ceiling
      end

      # Does this plan include a boolean feature?
      def includes_feature?(name)
        @features.include?(name.to_sym)
      end

      def limits
        @limits.dup
      end

      def features
        @features.dup
      end

      # Serialize for API/frontend consumption.
      def to_h
        {
          key: @key.to_s,
          name: @name,
          description: @description,
          featured: @featured,
          free: free?,
          prices: @prices.transform_values { |p| p.dup },
          limits: @limits.transform_values { |v| v == UNLIMITED ? 'unlimited' : v },
          features: @features.map(&:to_s)
        }
      end
    end
  end
end
