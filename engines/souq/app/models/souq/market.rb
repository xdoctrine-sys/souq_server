# frozen_string_literal: true

module Souq
  class Market < ApplicationRecord
    include TaxonomyFields

    has_many :market_categories, dependent: :destroy, inverse_of: :market
    has_many :categories, through: :market_categories
  end
end
