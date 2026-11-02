# frozen_string_literal: true

module Souq
  module REST
    # Serializes the effective attribute schema of one category, as returned by
    # `GET /api/v1/souq/categories/:code/schema` (design section 6.1). It renders
    # the envelope built once per request: no query is issued here, the category
    # labels and the attribute entries come from the in-memory snapshot.
    class SchemaSerializer < ActiveModel::Serializer
      attribute :category
      attribute :taxonomy_version
      # `attributes` is also an ActiveModel::Serializer method, so the value is
      # provided by a block instead of naming a method after it.
      attribute :attributes do
        object.attributes
      end

      def category
        entry = object.category
        { code: entry[:code], name_en: entry[:name_en], name_ar: entry[:name_ar], path: entry[:path] }
      end

      def taxonomy_version
        object.taxonomy_version
      end
    end
  end
end
