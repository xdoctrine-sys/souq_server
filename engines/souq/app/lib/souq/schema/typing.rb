# frozen_string_literal: true

require 'bigdecimal'
require 'date'

module Souq
  module Schema
    # Strict JSON coercion for attribute values (design section 3.6).
    #
    # Shared by the effective-schema resolver (to check `default_value`) and by
    # Souq::ListingAttributesValidator (to check submitted values), so both
    # agree on what a valid value is. Decimals are always normalized to a
    # string: a float would lose the exact amount.
    module Typing
      CONTROL_CHARACTERS = /[\u0000-\u001F\u007F]/
      DATE = /\A\d{4}-\d{2}-\d{2}\z/
      DECIMAL = /\A-?\d+(\.\d+)?\z/
      DEFAULT_MAX_LENGTH = 1000

      module_function

      # Returns [normalized_value, error_code]. `error_code` is nil on success.
      def normalize(data_type, value, min: nil, max: nil, max_length: nil)
        case data_type
        when 'integer' then normalize_integer(value, min, max)
        when 'decimal' then normalize_decimal(value, min, max)
        when 'boolean' then normalize_boolean(value)
        when 'text' then normalize_text(value, max_length)
        when 'date' then normalize_date(value)
        else [nil, 'invalid_type']
        end
      end

      def to_decimal(value)
        return if value.nil?
        return value if value.is_a?(BigDecimal)

        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def normalize_integer(value, min, max)
        return [nil, 'invalid_type'] unless value.is_a?(Integer)
        return [nil, 'out_of_bounds'] if out_of_bounds?(BigDecimal(value), min, max)

        [value, nil]
      end

      def normalize_decimal(value, min, max)
        return [nil, 'invalid_type'] unless value.is_a?(Integer) || value.is_a?(String)
        return [nil, 'invalid_type'] if value.is_a?(String) && !DECIMAL.match?(value.strip)

        decimal = to_decimal(value.is_a?(String) ? value.strip : value)
        return [nil, 'invalid_type'] if decimal.nil?
        return [nil, 'out_of_bounds'] if out_of_bounds?(decimal, min, max)

        [decimal_string(decimal), nil]
      end

      def normalize_boolean(value)
        return [value, nil] if [true, false].include?(value)

        [nil, 'invalid_type']
      end

      def normalize_text(value, max_length)
        return [nil, 'invalid_type'] unless value.is_a?(String)
        return [nil, 'invalid_text'] if CONTROL_CHARACTERS.match?(value)

        text = value.squish
        return [nil, 'too_long'] if text.length > (max_length || DEFAULT_MAX_LENGTH)

        [text, nil]
      end

      def normalize_date(value)
        return [nil, 'invalid_type'] unless value.is_a?(String) && DATE.match?(value)

        begin
          Date.iso8601(value)
        rescue ArgumentError
          return [nil, 'invalid_date']
        end
        [value, nil]
      end

      def out_of_bounds?(decimal, min, max)
        (min && decimal < min) || (max && decimal > max)
      end

      def decimal_string(decimal)
        decimal.frac.zero? ? decimal.to_i.to_s : decimal.to_s('F')
      end
    end
  end
end
