# frozen_string_literal: true

module Souq
  module Schema
    # Computes the effective schema of one category from the rules of its
    # ancestors and of itself, root first (design section 3.4).
    #
    # The resolver is pure: it only reads a Souq::Schema::Catalog and the
    # ordered `levels`, never the database, so the cache can precompute every
    # category and the write services can replay it inside a transaction.
    class Resolve
      OPTION_TYPES = %w(single_option multi_option).freeze

      def self.call(...)
        new(...).call
      end

      # Builds the `{ code => { id:, code:, path: } }` view shared by the cache
      # and the write services from raw `[id, code, ancestor_ids]` rows.
      def self.categories_from_rows(rows)
        codes = rows.to_h { |id, code, _ancestor_ids| [id, code] }
        rows.to_h do |id, code, ancestor_ids|
          [code, { id: id, code: code, path: ancestor_ids.map { |ancestor_id| codes.fetch(ancestor_id) } + [code] }]
        end
      end

      def self.for_category(catalog:, categories:, category:)
        levels = category[:path].map do |code|
          { category_code: code, rules: catalog.rules_for(categories.fetch(code)[:id]) }
        end
        call(catalog:, category:, levels:)
      end

      def initialize(catalog:, category:, levels:)
        @catalog = catalog
        @category = category
        @levels = levels
        @entries = {}
        @issues = []
        @warnings = []
      end

      def call
        @levels.each { |level| apply_level(level) }
        finish
      end

      private

      def apply_level(level)
        level[:rules].each do |rule|
          case rule[:mode]
          when 'enable' then apply_enable(rule)
          when 'override' then apply_override(rule)
          when 'disable' then apply_disable(rule)
          end
        end
      end

      def apply_enable(rule)
        definition = active_definition(rule[:definition_code])
        return if definition.nil?

        code = definition[:code]
        return issue(code, 'enable_already_inherited', 'is already inherited; use override') if @entries.key?(code)

        config = stringify(rule[:config])
        @entries[code] = {
          definition: definition,
          required: rule[:required] ? true : false,
          position: rule[:position] || definition[:position],
          min: config.key?('min_value') ? Typing.to_decimal(config['min_value']) : definition[:min_value],
          max: config.key?('max_value') ? Typing.to_decimal(config['max_value']) : definition[:max_value],
          max_length: definition[:max_length],
          default_value: config['default_value'],
          allowed_option_codes: config['allowed_option_codes'],
          filter_widget: config.key?('filter_widget') ? config['filter_widget'] : definition[:filter_widget],
          condition: rule[:condition],
        }
        validate_allowed_codes(code, config['allowed_option_codes'], @catalog.active_option_codes(code)) if config.key?('allowed_option_codes')
        validate_bounds(code) if config.key?('min_value') || config.key?('max_value')
      end

      def apply_override(rule)
        definition = active_definition(rule[:definition_code])
        return if definition.nil?

        code = definition[:code]
        entry = @entries[code]
        return issue(code, 'override_without_inherited', 'is not inherited; use enable') if entry.nil?

        config = stringify(rule[:config])
        entry[:required] = rule[:required] unless rule[:required].nil?
        entry[:position] = rule[:position] unless rule[:position].nil?
        # An override may replace the condition, but a rule that carries none
        # keeps the inherited one (design section 3.4 lists `required`,
        # `position` and `config` as merged, and the prompt says an override
        # "can" change the condition). Clearing a condition is out of scope.
        entry[:condition] = rule[:condition] unless rule[:condition].nil?
        override_options(code, entry, config['allowed_option_codes']) if config.key?('allowed_option_codes')
        override_min(code, entry, config['min_value']) if config.key?('min_value')
        override_max(code, entry, config['max_value']) if config.key?('max_value')
        entry[:default_value] = config['default_value'] if config.key?('default_value')
        entry[:filter_widget] = config['filter_widget'] if config.key?('filter_widget')
        validate_bounds(code) if config.key?('min_value') || config.key?('max_value')
      end

      def apply_disable(rule)
        definition = active_definition(rule[:definition_code])
        return if definition.nil?

        @entries.delete(definition[:code])
      end

      def override_options(code, entry, restriction)
        active = @catalog.active_option_codes(code)
        validate_allowed_codes(code, restriction, active)
        inherited = entry[:allowed_option_codes] || active
        widened = Array(restriction).uniq - inherited
        issue(code, 'override_widens_options', "cannot add options the ancestors did not allow: #{widened.join(', ')}") if widened.any?
        entry[:allowed_option_codes] = Array(restriction).uniq
      end

      def override_min(code, entry, raw)
        value = Typing.to_decimal(raw)
        inherited = entry[:min]
        issue(code, 'override_widens_bounds', 'cannot lower the inherited minimum') if inherited && value && value < inherited
        entry[:min] = value
      end

      def override_max(code, entry, raw)
        value = Typing.to_decimal(raw)
        inherited = entry[:max]
        issue(code, 'override_widens_bounds', 'cannot raise the inherited maximum') if inherited && value && value > inherited
        entry[:max] = value
      end

      def validate_allowed_codes(code, restriction, active_codes)
        all_codes = @catalog.options(code).pluck(:code)
        Array(restriction).map(&:to_s).uniq.each do |option_code|
          if !all_codes.include?(option_code)
            issue(code, 'unknown_option', "references unknown option #{option_code}")
          elsif !active_codes.include?(option_code)
            issue(code, 'inactive_option', "references inactive option #{option_code}")
          end
        end
      end

      def validate_bounds(code)
        entry = @entries[code]
        return unless entry[:min] && entry[:max] && entry[:min] > entry[:max]

        issue(code, 'invalid_bounds', 'minimum is greater than maximum')
      end

      def finish
        validate_dependencies
        validate_conditions
        validate_defaults
        attributes = @entries.values.sort_by { |entry| [entry[:position], entry[:definition][:code]] }.map { |entry| build_entry(entry) }
        Result.new(attributes: deep_freeze(attributes), issues: @issues, warnings: @warnings)
      end

      def build_entry(entry)
        definition = entry[:definition]
        {
          code: definition[:code],
          name_en: definition[:name_en],
          name_ar: definition[:name_ar],
          data_type: definition[:data_type],
          required: entry[:required],
          widget: entry[:filter_widget],
          unit: definition[:unit],
          min: entry[:min],
          max: entry[:max],
          max_length: entry[:max_length],
          default_value: entry[:default_value],
          searchable: definition[:searchable],
          position: entry[:position],
          depends_on: definition[:depends_on],
          condition: build_condition(entry[:condition]),
          options: build_options(entry),
        }
      end

      def build_condition(condition)
        return if condition.nil?

        { attribute: condition['attribute'] || condition[:attribute], in: Array(condition['in'] || condition[:in]) }
      end

      def build_options(entry)
        definition = entry[:definition]
        return [] unless OPTION_TYPES.include?(definition[:data_type])

        active = @catalog.active_options(definition[:code])
        restriction = definition[:depends_on] ? nil : entry[:allowed_option_codes]
        active = active.select { |option| restriction.include?(option[:code]) } if restriction
        active.map do |option|
          { code: option[:code], name_en: option[:name_en], name_ar: option[:name_ar],
            parent_option: option[:parent_option], position: option[:position] }
        end
      end

      def validate_dependencies
        @entries.each_value do |entry|
          pilot = entry[:definition][:depends_on]
          next if pilot.nil? || @entries.key?(pilot)

          issue(entry[:definition][:code], 'missing_dependency', "depends on #{pilot} which is not in the effective schema")
        end
      end

      def validate_conditions
        @entries.each_value do |entry|
          condition = entry[:condition]
          next if condition.nil?

          validate_condition(entry, condition)
        end
      end

      def validate_condition(entry, condition)
        code = entry[:definition][:code]
        pilot_code = condition['attribute'] || condition[:attribute]
        allowed = Array(condition['in'] || condition[:in])
        pilot = @entries[pilot_code]
        return issue(code, 'condition_missing_attribute', "condition pilot #{pilot_code} is not in the effective schema") if pilot.nil?
        return issue(code, 'condition_invalid_attribute_type', "condition pilot #{pilot_code} is not a single_option") unless pilot[:definition][:data_type] == 'single_option'
        return issue(code, 'condition_chained', "condition pilot #{pilot_code} is itself conditional") if pilot[:condition]

        pilot_codes = @catalog.active_option_codes(pilot_code)
        unknown = allowed - pilot_codes
        issue(code, 'condition_unknown_option', "condition references unknown options: #{unknown.join(', ')}") if unknown.any?
        available = pilot[:allowed_option_codes] || pilot_codes
        warning(code, 'condition_never_true', "restriction makes the condition on #{pilot_code} never true") if unknown.empty? && (allowed & available).empty?
      end

      def validate_defaults
        @entries.each_value do |entry|
          value = entry[:default_value]
          next if value.nil?

          invalid_default?(entry, value) && issue(entry[:definition][:code], 'invalid_default', 'does not match the definition type or bounds')
        end
      end

      def invalid_default?(entry, value)
        definition = entry[:definition]
        if definition[:data_type] == 'multi_option'
          codes = entry[:allowed_option_codes] || @catalog.active_option_codes(definition[:code])
          !(value.is_a?(Array) && value.all?(String) && value.uniq.size == value.size && (value - codes).empty?)
        elsif OPTION_TYPES.include?(definition[:data_type])
          codes = definition[:depends_on] ? @catalog.active_option_codes(definition[:code]) : (entry[:allowed_option_codes] || @catalog.active_option_codes(definition[:code]))
          !(value.is_a?(String) && codes.include?(value))
        else
          _normalized, error = Typing.normalize(definition[:data_type], value, min: entry[:min], max: entry[:max], max_length: entry[:max_length])
          !error.nil?
        end
      end

      def active_definition(code)
        definition = @catalog.definition(code)
        definition if definition && definition[:active]
      end

      # A direct SQL write or a broken import can leave a non-object config
      # behind despite the CHECK constraint; treat it as empty instead of
      # failing the whole snapshot load for every request.
      def stringify(config)
        return {} unless config.is_a?(Hash)

        config.to_h { |key, value| [key.to_s, value] }
      end

      def issue(attribute, code, message)
        @issues << Issue.new(category: @category[:code], attribute: attribute, code: code, message: message)
      end

      def warning(attribute, code, message)
        @warnings << Issue.new(category: @category[:code], attribute: attribute, code: code, message: message)
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each do |key, item|
            deep_freeze(key)
            deep_freeze(item)
          end
        when Array
          value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end
  end
end
