# frozen_string_literal: true

module Souq
  class Listing < ApplicationRecord
    enum :price_mode, { fixed: 0, negotiable: 1, on_request: 2, free: 3, none: 4 }, prefix: true, validate: true
    enum :price_period, { once: 0, day: 1, week: 2, month: 3, year: 4 }, prefix: true, validate: true
    enum :sale_mode, { classified: 0, auction: 1 }, prefix: true, validate: true
    enum :state, { active: 0, reserved: 1, sold: 2, expired: 3, hidden: 4 }, prefix: true, validate: true

    belongs_to :status, class_name: '::Status'
    belongs_to :account, class_name: '::Account'
    belongs_to :category, optional: true
    belongs_to :location, optional: true

    validates :status_id, uniqueness: true
    validates :title, presence: true, length: { in: 1..140 }
    validates :category_code, :published_at, presence: true
    validates :local, inclusion: { in: [true, false] }
    validates :price_minor, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 9_223_372_036_854_775_807 }, allow_nil: true
    validates :currency, inclusion: { in: ->(_) { Souq.configuration.allowed_currencies } }, allow_nil: true
    validate :empty_attributes
    validate :consistent_price
    validate :consistent_status
    validate :local_category, on: :create

    private

    def empty_attributes
      errors.add(:attribute_values, 'must be an empty object until the attribute validator is available') unless attribute_values == {}
    end

    def consistent_price
      priced = price_mode_fixed? || price_mode_negotiable?
      if priced
        errors.add(:price_minor, 'is required') if price_minor.nil?
        errors.add(:currency, 'is required') if currency.nil?
      else
        errors.add(:price_minor, 'must be absent') unless price_minor.nil?
        errors.add(:currency, 'must be absent') unless currency.nil?
      end
      errors.add(:price_period, 'must be once without a priced mode') unless priced || price_period_once?
    end

    def consistent_status
      return unless status

      errors.add(:status, 'must be local') unless status.local?
      errors.add(:local, 'must match the status') unless local == status.local?
      errors.add(:status, 'must be public or unlisted') unless status.public_visibility? || status.unlisted_visibility?
      errors.add(:status, 'must not be a reblog') if status.reblog?
      errors.add(:account, 'must own the status') unless account_id == status.account_id
    end

    def local_category
      return unless local

      errors.add(:category, 'must be active and listable') unless category&.active? && category.listable?
      errors.add(:category_code, 'must match category') unless category && category_code == category.code
    end
  end
end
