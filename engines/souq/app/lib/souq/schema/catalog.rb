# frozen_string_literal: true

module Souq
  module Schema
    # Immutable catalog of attribute definitions, their options and the
    # per-category rules, loaded in exactly three queries (one per table).
    #
    # The resolver and the write services both read a catalog, so the number of
    # SQL queries never depends on the size of the tree or the number of
    # attributes.
    class Catalog
      def self.load
        definitions, definition_id_to_code = load_definitions
        options = load_options(definition_id_to_code)
        rules = load_rules(definition_id_to_code)
        new(definitions:, options_by_definition: options, rules_by_category_id: rules)
      end

      def self.load_definitions
        rows = Souq::AttributeDefinition.pluck(
          :id, :code, :name_en, :name_ar, :data_type, :unit, :min_value, :max_value,
          :max_length, :depends_on_id, :filter_widget, :searchable, :position, :active
        )
        id_to_code = rows.to_h { |row| [row[0], row[1]] }
        # `pluck` returns the deserialized enum label ("single_option"), not the
        # stored integer, so the plucked value is already the code the resolver
        # compares against.
        definitions = rows.to_h do |id, code, name_en, name_ar, data_type, unit, min_value, max_value, max_length, depends_on_id, filter_widget, searchable, position, active|
          [code, {
            id: id, code: code, name_en: name_en, name_ar: name_ar,
            data_type: data_type, unit: unit,
            min_value: min_value, max_value: max_value, max_length: max_length,
            depends_on: id_to_code[depends_on_id], filter_widget: filter_widget,
            searchable: searchable, position: position, active: active
          }]
        end
        [definitions, id_to_code]
      end
      private_class_method :load_definitions

      def self.load_options(definition_id_to_code)
        rows = Souq::AttributeOption.order(:definition_id, :position, :id).pluck(
          :id, :definition_id, :code, :parent_option_id, :name_en, :name_ar, :position, :active
        )
        option_id_to_code = rows.to_h { |row| [row[0], row[2]] }
        options = {}
        rows.each do |_id, definition_id, code, parent_option_id, name_en, name_ar, position, active|
          definition_code = definition_id_to_code[definition_id]
          next if definition_code.nil?

          (options[definition_code] ||= []) << {
            code: code, name_en: name_en, name_ar: name_ar,
            parent_option: option_id_to_code[parent_option_id], position: position, active: active
          }
        end
        options
      end
      private_class_method :load_options

      def self.load_rules(definition_id_to_code)
        rows = Souq::CategoryAttribute.order(:category_id, :id).pluck(
          :category_id, :definition_id, :mode, :required, :position, :config, :condition
        )
        # `pluck` returns the enum label ("enable"), see load_definitions.
        rows.each_with_object({}) do |(category_id, definition_id, mode, required, position, config, condition), hash|
          definition_code = definition_id_to_code[definition_id]
          next if definition_code.nil?

          (hash[category_id] ||= []) << {
            definition_code: definition_code, mode: mode, required: required,
            position: position, config: config || {}, condition: condition
          }
        end
      end
      private_class_method :load_rules

      def initialize(definitions:, options_by_definition:, rules_by_category_id:)
        @definitions = definitions.freeze
        @options_by_definition = options_by_definition.transform_values { |list| list.sort_by { |option| [option[:position], option[:code]] }.freeze }.freeze
        @rules_by_category_id = rules_by_category_id.each_value(&:freeze).freeze
        freeze
      end

      def definition(code)
        @definitions[code]
      end

      def options(code)
        @options_by_definition.fetch(code, [])
      end

      def active_options(code)
        options(code).select { |option| option[:active] }
      end

      def active_option_codes(code)
        active_options(code).pluck(:code)
      end

      def rules_for(category_id)
        @rules_by_category_id.fetch(category_id, [])
      end
    end
  end
end
