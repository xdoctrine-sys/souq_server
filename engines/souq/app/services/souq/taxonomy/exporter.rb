# frozen_string_literal: true

module Souq
  module Taxonomy
    # Produces the versioned document the importer accepts (plan T3, design 7.3).
    #
    # The output is deterministic: markets are ordered by position, categories
    # are walked depth first by position, so exporting the same database twice
    # gives the same document and an export can be re-imported as is. Nothing is
    # invented: a missing value stays null and no label is defaulted.
    class Exporter
      def self.call(...)
        new.call(...)
      end

      def call
        @categories = Category.order(:position, :id).to_a
        @code_by_id = @categories.to_h { |row| [row.id, row.code] }
        {
          'format_version' => Document::FORMAT_VERSION,
          'taxonomy_version' => read_version,
          'markets' => markets,
          'categories' => ordered_categories,
          'attributes' => [],
          'locations' => [],
        }
      end

      private

      # The version is read directly, without building a snapshot: an export
      # only needs the number (design 8.1, the database is the single source).
      def read_version
        Setting.uncached { Setting.where(id: 1).pick(:taxonomy_version) } || TaxonomyCache::BOOTSTRAP_VERSION
      end

      def markets
        Market.includes(:market_categories).order(:position, :id).map { |row| market_hash(row) }
      end

      def ordered_categories
        by_parent = @categories.group_by(&:parent_id)
        walk(by_parent, nil).map { |row| category_hash(row) }
      end

      def walk(by_parent, parent_id)
        by_parent.fetch(parent_id, []).flat_map { |row| [row, *walk(by_parent, row.id)] }
      end

      def market_hash(row)
        {
          'code' => row.code,
          'name_en' => row.name_en,
          'name_ar' => row.name_ar,
          'description_en' => row.description_en,
          'description_ar' => row.description_ar,
          'icon' => row.icon,
          'cover_url' => row.cover_url,
          'color' => row.color,
          'position' => row.position,
          'active' => row.active,
          'categories' => row.market_categories.sort_by { |link| [link.position, link.id] }.map { |link| @code_by_id[link.category_id] },
        }
      end

      def category_hash(row)
        {
          'code' => row.code,
          'parent_code' => @code_by_id[row.parent_id],
          'name_en' => row.name_en,
          'name_ar' => row.name_ar,
          'description_en' => row.description_en,
          'description_ar' => row.description_ar,
          'icon' => row.icon,
          'cover_url' => row.cover_url,
          'color' => row.color,
          'hashtag' => row.hashtag,
          'hashtag_ar' => row.hashtag_ar,
          'position' => row.position,
          'active' => row.active,
          'listable' => row.listable,
        }
      end
    end
  end
end
