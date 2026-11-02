# frozen_string_literal: true

module Souq
  # Validates and normalizes the `attribute_values` of a listing against the
  # effective schema of its category (design section 3.6).
  #
  # In T6 the validator is deliberately not wired into listing creation or
  # update: that is T11b. It reads only the in-memory snapshot (schema and
  # catalog), never the database, so it is safe to call inside a request that
  # already holds one.
  #
  # The result exposes `valid?`, the normalized `values` and `errors` keyed by
  # attribute code: `{ "mileage_km" => [{ code: "not_allowed_for_condition",
  # message: "..." }] }`. Category-wide problems use the reserved key
  # `_category` because they belong to no field.
  class ListingAttributesValidator
    CATEGORY_KEY = '_category'

    # Returned by the per-value normalizers to signal "an error was recorded".
    INVALID = Object.new
    private_constant :INVALID

    MESSAGES = {
      'unknown_category' => 'category has no effective schema',
      'invalid_schema' => 'category schema is invalid',
      'invalid_values' => 'attribute values must be an object',
      'unknown_attribute' => 'is not part of the category schema',
      'required' => 'is required',
      'not_allowed_for_condition' => 'is not allowed while the condition is false',
      'invalid_type' => 'has the wrong type',
      'out_of_bounds' => 'is out of bounds',
      'invalid_text' => 'contains forbidden characters',
      'too_long' => 'is too long',
      'invalid_date' => 'is not a valid date',
      'unknown_option' => 'is not a known option',
      'inactive_option' => 'refers to an inactive option',
      'not_allowed_option' => 'is not allowed for this category',
      'duplicate_option' => 'repeats an option',
      'dependency_not_satisfied' => 'requires the attribute it depends on',
      'parent_option_mismatch' => 'does not belong to the selected parent option',
    }.freeze

    class Result
      attr_reader :values, :errors

      def initialize(values:, errors:)
        @values = values
        @errors = errors
        freeze
      end

      def valid?
        @errors.empty?
      end

      def error_codes
        @errors.transform_values { |issues| issues.map { |issue| issue[:code] } }
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(category:, values:)
      @category = category
      @raw_values = values
      @errors = {}
      @normalized = {}
    end

    def call
      @snapshot = Souq::TaxonomyCache.snapshot
      schema = @snapshot.schema(schema_code)
      return failure('unknown_category') if schema.nil?
      return failure('invalid_schema') if schema.invalid?
      return failure('invalid_values') unless @raw_values.is_a?(Hash)

      submitted = @raw_values.transform_keys(&:to_s)
      reject_unknown_keys(schema, submitted)
      schema.attributes.each { |entry| validate_entry(entry, submitted) }
      Result.new(values: @normalized, errors: @errors)
    end

    private

    def schema_code
      @category.is_a?(Souq::Category) ? @category.code : @category.to_s
    end

    def failure(code)
      @errors[CATEGORY_KEY] = [{ code: code, message: MESSAGES.fetch(code) }]
      Result.new(values: {}, errors: @errors)
    end

    def add(code, error_code)
      (@errors[code] ||= []) << { code: error_code, message: MESSAGES.fetch(error_code, error_code) }
    end

    def reject_unknown_keys(schema, submitted)
      (submitted.keys - schema.codes).each { |key| add(key, 'unknown_attribute') }
    end

    def validate_entry(entry, submitted)
      code = entry[:code]
      met = condition_met?(entry, submitted)

      unless submitted.key?(code)
        add(code, 'required') if entry[:required] && met
        return
      end

      return add(code, 'not_allowed_for_condition') unless met

      value = normalize_value(entry, submitted[code], submitted)
      @normalized[code] = value unless value.equal?(INVALID)
    end

    def condition_met?(entry, submitted)
      condition = entry[:condition]
      return true if condition.nil?

      condition[:in].include?(submitted[condition[:attribute]])
    end

    def normalize_value(entry, value, submitted)
      case entry[:data_type]
      when 'single_option' then normalize_single(entry, value, submitted)
      when 'multi_option' then normalize_multi(entry, value)
      else normalize_scalar(entry, value)
      end
    end

    def normalize_scalar(entry, value)
      normalized, error = Souq::Schema::Typing.normalize(
        entry[:data_type], value, min: entry[:min], max: entry[:max], max_length: entry[:max_length]
      )
      return invalid(entry, error) if error

      normalized
    end

    def normalize_single(entry, value, submitted)
      return invalid(entry, 'invalid_type') unless value.is_a?(String)

      code = entry[:code]
      return invalid(entry, 'unknown_option') unless all_option_codes(code).include?(value)
      return invalid(entry, 'inactive_option') unless active_option_codes(code).include?(value)
      return invalid(entry, 'not_allowed_option') unless option_codes(entry).include?(value)

      validate_parent_option(entry, value, submitted) || value
    end

    def normalize_multi(entry, value)
      return invalid(entry, 'invalid_type') unless value.is_a?(Array) && value.all?(String)
      return invalid(entry, 'duplicate_option') unless value.uniq.size == value.size

      code = entry[:code]
      all = all_option_codes(code)
      active = active_option_codes(code)
      allowed = option_codes(entry)
      value.each do |option_code|
        return invalid(entry, 'unknown_option') unless all.include?(option_code)
        return invalid(entry, 'inactive_option') unless active.include?(option_code)
        return invalid(entry, 'not_allowed_option') unless allowed.include?(option_code)
      end
      value
    end

    # `model` depends on `brand`: the chosen option must be a child of the
    # selected brand. A missing brand is its own, clearer error.
    def validate_parent_option(entry, value, submitted)
      pilot = entry[:depends_on]
      return nil if pilot.nil?

      chosen = submitted[pilot]
      return invalid(entry, 'dependency_not_satisfied') if chosen.nil? || chosen == ''

      option = option_codes_entry(entry, value)
      return invalid(entry, 'parent_option_mismatch') if option.nil? || option[:parent_option] != chosen

      nil
    end

    def invalid(entry, error_code)
      add(entry[:code], error_code)
      INVALID
    end

    def option_codes(entry)
      entry[:options].pluck(:code)
    end

    def option_codes_entry(entry, value)
      entry[:options].find { |option| option[:code] == value }
    end

    def all_option_codes(code)
      @snapshot.catalog.options(code).pluck(:code)
    end

    def active_option_codes(code)
      @snapshot.catalog.active_option_codes(code)
    end
  end
end
