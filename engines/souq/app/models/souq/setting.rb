# frozen_string_literal: true

module Souq
  class Setting < ApplicationRecord
    attribute :id, :integer, default: 1

    validates :id, inclusion: { in: [1] }, uniqueness: true
    validates :taxonomy_version, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  end
end
