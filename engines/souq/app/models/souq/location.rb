# frozen_string_literal: true

module Souq
  class Location < ApplicationRecord
    include TaxonomyFields

    enum :kind, { region: 0, city: 1, area: 2 }, validate: true

    belongs_to :parent, class_name: 'Souq::Location', optional: true, inverse_of: :children
    has_many :children, class_name: 'Souq::Location', foreign_key: :parent_id, inverse_of: :parent, dependent: :restrict_with_error

    before_validation :initialize_ancestry, on: :create

    validates :depth, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 2 }
    validate :consistent_ancestry
    validate :consistent_kind

    private

    def initialize_ancestry
      self.ancestor_ids = parent ? parent.ancestor_ids + [parent.id] : []
      self.depth = ancestor_ids.size
    end

    def consistent_ancestry
      expected = parent ? parent.ancestor_ids + [parent.id] : []
      errors.add(:ancestor_ids, 'does not match parent') unless ancestor_ids == expected
      errors.add(:depth, 'does not match ancestors') unless depth == ancestor_ids&.size
      errors.add(:parent, 'creates a cycle') if id && (parent_id == id || ancestor_ids&.include?(id))
    end

    def consistent_kind
      errors.add(:parent, 'must be absent for a region and present for a city or area') unless region? == parent.nil?
    end
  end
end
