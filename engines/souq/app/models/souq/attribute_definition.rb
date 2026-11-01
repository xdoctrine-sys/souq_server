# frozen_string_literal: true

module Souq
  class AttributeDefinition < ApplicationRecord
    include AttributeFields

    enum :data_type, { single_option: 0, multi_option: 1, integer: 2, decimal: 3, boolean: 4, text: 5, date: 6 }, prefix: true, validate: true
    enum :filter_widget, { select: 0, multi_select: 1, range: 2, toggle: 3, none: 4 }, prefix: true, validate: { allow_nil: true }

    belongs_to :depends_on, class_name: 'Souq::AttributeDefinition', optional: true, inverse_of: :dependent_definitions
    has_many :dependent_definitions, class_name: 'Souq::AttributeDefinition', foreign_key: :depends_on_id, inverse_of: :depends_on, dependent: :restrict_with_error
    has_many :options, class_name: 'Souq::AttributeOption', foreign_key: :definition_id, inverse_of: :definition, dependent: :delete_all
    has_many :category_attributes, foreign_key: :definition_id, inverse_of: :definition, dependent: :restrict_with_error

    validates :code, uniqueness: true
    validates :searchable, inclusion: { in: [true, false] }
    validates :min_value, :max_value, numericality: true, allow_nil: true
    validates :max_length, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validate :consistent_bounds
    validate :valid_dependency
    validate :preserve_option_shape, on: :update

    def option_type?
      data_type_single_option? || data_type_multi_option?
    end

    private

    def consistent_bounds
      unless data_type_integer? || data_type_decimal?
        errors.add(:min_value, 'is only available for numeric types') unless min_value.nil?
        errors.add(:max_value, 'is only available for numeric types') unless max_value.nil?
      end
      errors.add(:max_value, 'must be at least min_value') if min_value && max_value && min_value > max_value
      errors.add(:max_length, 'is only available for text') if !max_length.nil? && !data_type_text?
    end

    def valid_dependency
      if depends_on
        errors.add(:depends_on, 'cannot refer to itself') if depends_on == self
        errors.add(:depends_on, 'must be single_option') unless depends_on.data_type_single_option?
        errors.add(:depends_on, 'must not depend on another definition') if depends_on.depends_on
        errors.add(:depends_on, 'cannot create a chain of dependencies') if dependent_definitions.exists?
      end
      errors.add(:data_type, 'must remain single_option while other definitions depend on it') if !data_type_single_option? && dependent_definitions.exists?
    end

    def preserve_option_shape
      return unless options.exists?

      errors.add(:depends_on_id, 'cannot change while options exist') if will_save_change_to_depends_on_id?
      errors.add(:data_type, 'must remain an option type while options exist') unless option_type?
    end
  end
end
