# frozen_string_literal: true

module Souq
  module REST
    # Serializes a Souq::Listing inside the `souq_listing` field of a status,
    # following SOUQ_CATEGORIES_DESIGN.md section 7.1. Category and location
    # labels come from the in-memory taxonomy snapshot, never from a query.
    class ListingSerializer < ActiveModel::Serializer
      attribute :id
      attribute :title
      attribute :category
      attribute :price
      attribute :location
      # `attributes` is also an ActiveModel::Serializer method, so the value is
      # provided by a block instead of naming a method after it.
      attribute :attributes do
        []
      end
      attribute :state
      attribute :taxonomy_version

      def id
        object.id.to_s
      end

      def category
        entry = Souq::TaxonomyCache.category(object.category_code)
        return if entry.nil?

        { code: entry[:code], name_en: entry[:name_en], name_ar: entry[:name_ar], path: entry[:path] }
      end

      def price
        { mode: object.price_mode, amount: amount, minor: object.price_minor, currency: object.currency, period: object.price_period }
      end

      def location
        entry = Souq::TaxonomyCache.location_by_id(object.location_id)
        return if entry.nil?

        { code: entry[:code], name_en: entry[:name_en], name_ar: entry[:name_ar] }
      end

      def state
        object.state
      end

      def taxonomy_version
        Souq::TaxonomyCache.version
      end

      private

      def amount
        return if object.price_minor.nil? || object.currency.nil?

        Souq::Money.to_decimal(object.price_minor, currency: object.currency)
      end
    end
  end
end
