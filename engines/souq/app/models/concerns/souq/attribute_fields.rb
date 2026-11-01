# frozen_string_literal: true

module Souq
  module AttributeFields
    extend ActiveSupport::Concern

    included do
      validates :code, presence: true, format: { with: /\A[a-z0-9_]{2,64}\z/ }
      validates :name_en, :name_ar, presence: true
      validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validates :active, inclusion: { in: [true, false] }
      validate :immutable_code, on: :update
    end

    private

    def immutable_code
      errors.add(:code, 'is immutable') if will_save_change_to_code?
    end
  end
end
