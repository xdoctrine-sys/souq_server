# frozen_string_literal: true

module Souq
  class AttributeOption < ApplicationRecord
    include AttributeFields

    belongs_to :definition, class_name: 'Souq::AttributeDefinition', inverse_of: :options
    belongs_to :parent_option, class_name: 'Souq::AttributeOption', optional: true, inverse_of: :child_options
    has_many :child_options, class_name: 'Souq::AttributeOption', foreign_key: :parent_option_id, inverse_of: :parent_option, dependent: :restrict_with_error

    validates :code, uniqueness: { scope: :definition_id }
    validate :valid_option_definition
    validate :consistent_parent_option

    private

    def valid_option_definition
      errors.add(:definition, 'must support options') if definition && !definition.option_type?
    end

    def consistent_parent_option
      return unless definition

      if definition.depends_on
        errors.add(:parent_option, 'is required for a dependent definition') unless parent_option
        errors.add(:parent_option, 'must belong to the depends_on definition') if parent_option && parent_option.definition_id != definition.depends_on_id
      elsif parent_option_id || parent_option
        errors.add(:parent_option, 'must be empty without a dependency')
      end
    end
  end
end
