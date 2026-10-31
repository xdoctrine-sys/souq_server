# frozen_string_literal: true

module Souq
  module Listings
    # Normalizes and validates the `listing` half of a create/update request.
    #
    # Every problem is collected and keyed by the name the client used
    # (`listing.price`, `listing.category`, ...) so the controller can render
    # `{ "error": ..., "details": { "listing.price": ["..."] } }` without
    # leaking internal attribute names.
    #
    # `category_required: false` is used by the update path: the category is
    # optional there and is never changed (design section 5.3, T11b).
    class Input
      PRICE_MODES = %w(fixed negotiable on_request free none).freeze
      PRICED_MODES = %w(fixed negotiable).freeze
      PRICE_PERIODS = %w(once day week month year).freeze
      MAX_TITLE_LENGTH = 140
      CONTROL_CHARACTERS = /[\u0000-\u001F\u007F]/

      attr_reader :category

      def initialize(raw, category_required: true)
        @raw = (raw || {}).to_h.symbolize_keys
        @category_required = category_required
        @details = {}
      end

      def validate!
        resolve_category
        resolve_title
        resolve_price
        resolve_location
        resolve_attributes

        raise ValidationError, @details unless @details.empty?

        self
      end

      def normalized
        {
          category: @category,
          title: @title,
          price_mode: @price_mode,
          price_minor: @price_minor,
          currency: @currency,
          price_period: @price_period,
          location: @location,
        }
      end

      private

      def add(field, message)
        (@details["listing.#{field}"] ||= []) << message
      end

      def blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?) || (value.is_a?(String) && value.strip.empty?)
      end

      def resolve_category
        code = @raw[:category]

        if blank?(code)
          add(:category, 'is required') if @category_required
          return
        end

        @category = Souq::Category.find_by(code: code.to_s)

        if @category.nil?
          add(:category, 'does not exist')
        elsif !@category.active?
          add(:category, 'is not active')
        elsif !@category.listable?
          add(:category, 'is not listable')
        end
      end

      def resolve_title
        raw = @raw[:title]

        unless raw.is_a?(String)
          add(:title, 'is required')
          return
        end

        if CONTROL_CHARACTERS.match?(raw)
          add(:title, 'must not contain control characters')
          return
        end

        title = raw.squish

        if title.empty?
          add(:title, 'is required')
        elsif title.length > MAX_TITLE_LENGTH
          add(:title, "is too long (maximum is #{MAX_TITLE_LENGTH} characters)")
        else
          @title = title
        end
      end

      def resolve_price
        mode = @raw[:price_mode]
        mode = mode.to_s unless mode.nil?

        if blank?(mode) || !PRICE_MODES.include?(mode)
          add(:price_mode, blank?(mode) ? 'is required' : "must be one of #{PRICE_MODES.join(', ')}")
          return
        end

        @price_mode = mode
        resolve_price_period!

        if PRICED_MODES.include?(mode)
          resolve_priced_attributes
        else
          resolve_unpriced_attributes
        end
      end

      def resolve_price_period!
        period = @raw[:price_period]
        period = period.to_s unless period.nil?
        period = 'once' if blank?(period)

        if PRICE_PERIODS.include?(period)
          @price_period = period
        else
          @price_period = 'once'
          add(:price_period, "must be one of #{PRICE_PERIODS.join(', ')}")
        end
      end

      def resolve_priced_attributes
        resolve_currency

        raw_price = @raw[:price]

        if blank?(raw_price)
          add(:price, 'is required')
          return
        end

        begin
          @price_minor = Souq::Money.to_minor(raw_price.is_a?(String) ? raw_price.strip : raw_price, currency: @currency || Souq.configuration.default_currency)
        rescue ArgumentError => e
          add(:price, e.message)
        end
      end

      def resolve_currency
        currency = @raw[:currency]
        currency = currency.to_s unless currency.nil?
        currency = Souq.configuration.default_currency if blank?(currency)

        if Souq.configuration.allowed_currencies.include?(currency)
          @currency = currency
        else
          add(:currency, 'is not an allowed currency')
        end
      end

      def resolve_unpriced_attributes
        add(:price, 'must be absent unless the price mode is fixed or negotiable') unless blank?(@raw[:price])
        add(:currency, 'must be absent unless the price mode is fixed or negotiable') unless blank?(@raw[:currency])
        add(:price_period, 'must be once unless the price mode is fixed or negotiable') unless @price_period == 'once'
      end

      def resolve_location
        code = @raw[:location]

        return if blank?(code)

        location = Souq::Location.find_by(code: code.to_s)

        if location.nil?
          add(:location, 'does not exist')
        elsif !location.active?
          add(:location, 'is not active')
        else
          @location = location
        end
      end

      def resolve_attributes
        raw = @raw[:attributes]

        return if blank?(raw)

        add(:attributes, 'must be empty until the attribute validator is available')
      end
    end
  end
end
