# frozen_string_literal: true

module Souq
  class MarketCategory < ApplicationRecord
    belongs_to :market, inverse_of: :market_categories
    belongs_to :category, inverse_of: :market_categories

    validates :category_id, uniqueness: { scope: :market_id }
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :featured, inclusion: { in: [true, false] }
  end
end
