# frozen_string_literal: true

module Souq
  class CategoryAttribute < ApplicationRecord
    CONFIG_KEYS = %w(allowed_option_codes min_value max_value default_value filter_widget).freeze

    enum :mode, { enable: 0, override: 1, disable: 2 }, prefix: true, validate: true

    belongs_to :category
    belongs_to :definition, class_name: 'Souq::AttributeDefinition', inverse_of: :category_attributes

    validates :definition_id, uniqueness: { scope: :category_id }
    validates :required, inclusion: { in: [true, false] }, allow_nil: true
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validate :empty_disabled_overrides
    validate :valid_config
    validate :valid_condition

    private

    def empty_disabled_overrides
      return unless mode_disable?

      errors.add(:required, 'must be empty when disabled') unless required.nil?
      errors.add(:position, 'must be empty when disabled') unless position.nil?
      errors.add(:config, 'must be empty when disabled') unless config == {}
      errors.add(:condition, 'must be empty when disabled') unless condition.nil?
    end

    def valid_config
      unless config.is_a?(Hash)
        errors.add(:config, 'must be an object')
        return
      end

      (config.keys - CONFIG_KEYS).each { |key| errors.add(:config, "contains unknown key #{key}") }
      errors.add(:config, 'allowed_option_codes must be a list of strings') if config.key?('allowed_option_codes') && !string_list?(config['allowed_option_codes'])
      errors.add(:config, 'filter_widget must be an allowed widget') if config.key?('filter_widget') && !AttributeDefinition.filter_widgets.key?(config['filter_widget'])
    end

    def valid_condition
      return if condition.nil?
      return if condition.is_a?(Hash) && condition.keys.sort == %w(attribute in) &&
                condition['attribute'].is_a?(String) &&
                string_list?(condition['in']) && condition['in'].any?

      errors.add(:condition, 'must contain only attribute (string) and in (nonempty list of strings)')
    end

    def string_list?(value)
      value.is_a?(Array) && value.all?(String)
    end
  end
end
