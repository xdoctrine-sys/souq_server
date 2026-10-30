# frozen_string_literal: true

module Souq
  class Category < ApplicationRecord
    include TaxonomyFields

    belongs_to :parent, class_name: 'Souq::Category', optional: true, inverse_of: :children
    has_many :children, class_name: 'Souq::Category', foreign_key: :parent_id, inverse_of: :parent, dependent: :restrict_with_error
    has_many :market_categories, dependent: :destroy, inverse_of: :category
    has_many :markets, through: :market_categories

    before_validation :initialize_ancestry, on: :create

    validates :hashtag, :hashtag_ar, format: { with: ::Tag::HASHTAG_NAME_RE }, allow_nil: true
    validates :depth, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 3 }
    validates :listable, inclusion: { in: [true, false] }
    validate :consistent_ancestry

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
  end
end
