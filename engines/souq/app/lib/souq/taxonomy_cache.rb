# frozen_string_literal: true

module Souq
  # Process-memory snapshot of the taxonomy tree (categories and locations).
  #
  # The snapshot is keyed by the taxonomy version. The version is read from
  # souq_settings once per render: `snapshot` memoizes the built Snapshot in
  # Souq::Current, which Rails clears at the end of every request and every
  # Sidekiq job, so the snapshot lives exactly one render. Outside those
  # boundaries (console, rake, one-off scripts) nothing clears Souq::Current,
  # so call Souq::Current.reset (or reset! below) to observe a version change.
  #
  # T2 increments the version in the same transaction as the tree writes.
  #
  # The serializer reads categories and locations from this snapshot, so it
  # never issues a SQL query for them once the snapshot is loaded.
  class TaxonomyCache
    BOOTSTRAP_VERSION = 1

    # Guards only the comparison and the swap of the process tree.
    MUTEX = Mutex.new

    # Immutable, coherent view of the taxonomy for a single version: the
    # category label and the version always come from the same read.
    class Snapshot
      attr_reader :version, :roots, :catalog

      def initialize(version:, categories:, categories_by_id:, children_by_id:, ancestors_by_code:, descendants_by_code:, roots:, locations_by_id:, catalog:, schemas:)
        @version = version
        @catalog = catalog
        @categories = deep_freeze(categories)
        @categories_by_id = deep_freeze(categories_by_id)
        @children_by_id = deep_freeze(children_by_id)
        @ancestors_by_code = deep_freeze(ancestors_by_code)
        @descendants_by_code = deep_freeze(descendants_by_code)
        @roots = deep_freeze(roots)
        @locations_by_id = deep_freeze(locations_by_id)
        @schemas = deep_freeze(schemas)
        freeze
      end

      # The effective schema of a category, resolved once when the tree was
      # loaded. Returns nil for an unknown code. A category whose rules cannot
      # be resolved carries a Souq::Schema::Result marked `invalid` instead of
      # failing the whole snapshot.
      def schema(code)
        return if code.nil?

        @schemas[code]
      end

      def category(code)
        return if code.nil?

        @categories[code]
      end

      def category_by_id(id)
        @categories_by_id[id]
      end

      def ancestors(code)
        @ancestors_by_code.fetch(code, [].freeze)
      end

      def children(code)
        entry = category(code)
        entry ? @children_by_id.fetch(entry[:id], [].freeze) : [].freeze
      end

      def descendants(code)
        @descendants_by_code.fetch(code, [].freeze)
      end

      def location(id)
        return if id.nil?

        @locations_by_id[id]
      end

      private

      def deep_freeze(value)
        case value
        when Hash
          value.each do |key, item|
            deep_freeze(key)
            deep_freeze(item)
          end
        when Array
          value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end

    class << self
      # The snapshot for the current request or job, built from exactly one
      # version read.
      def snapshot
        ::Souq::Current.taxonomy_snapshot ||= build_snapshot
      end

      def version
        snapshot.version
      end

      def category(code)
        snapshot.category(code)
      end

      def location_by_id(id)
        snapshot.location(id)
      end

      def schema(code)
        snapshot.schema(code)
      end

      # Drops the process tree and the request snapshot. Used by specs; in
      # production a version bump plus the natural request boundary is enough.
      def reset!
        MUTEX.synchronize do
          @tree = nil
          @tree_version = nil
        end
        ::Souq::Current.taxonomy_snapshot = nil
      end

      private

      def build_snapshot
        version = read_version
        tree = tree_for(version)
        Snapshot.new(version: version, **tree)
      end

      # The version SELECT happens outside the mutex; the mutex only guards the
      # comparison and the swap of the process tree. The tree load (SQL) runs
      # under the mutex, but only when the version changed, which is rare.
      def tree_for(version)
        MUTEX.synchronize do
          if @tree.nil? || @tree_version != version
            @tree = load_tree
            @tree_version = version
          end
          @tree
        end
      end

      def read_version
        Souq::Setting.uncached { Souq::Setting.where(id: 1).pick(:taxonomy_version) } || BOOTSTRAP_VERSION
      end

      # Two queries for the tree (categories, locations) plus exactly three for
      # the attribute catalog (definitions, options, rules), so switching the
      # attribute schema in is a constant cost whatever the tree size. The
      # effective schema of every category is then resolved in memory.
      def load_tree
        tree = load_categories
        catalog = Souq::Schema::Catalog.load
        schemas = build_schemas(tree[:categories], catalog)
        log_invalid_schemas(schemas)
        tree.merge(locations_by_id: load_locations, catalog: catalog, schemas: schemas)
      end

      def build_schemas(categories, catalog)
        categories.to_h do |code, category|
          [code, Souq::Schema::Resolve.for_category(catalog: catalog, categories: categories, category: category)]
        end
      end

      # A direct SQL write or a broken import can leave rules that do not
      # resolve. The snapshot must still load for everyone else: the category
      # keeps an `invalid` schema (rendered as 503, refused by the validator)
      # and the problem is logged without any sensitive data.
      def log_invalid_schemas(schemas)
        schemas.each_value do |result|
          next unless result.invalid?

          result.issues.each do |issue|
            Rails.logger.warn("[souq] invalid effective schema: category=#{issue.category} attribute=#{issue.attribute} code=#{issue.code}")
          end
        end
      end

      def load_categories
        rows = Souq::Category.order(:position, :id).pluck(:id, :code, :name_en, :name_ar, :ancestor_ids, :parent_id, :position, :depth, :active)
        codes = rows.to_h { |row| [row[0], row[1]] }
        categories = rows.to_h do |id, code, name_en, name_ar, ancestor_ids, parent_id, position, depth, active|
          path = ancestor_ids.map { |ancestor_id| codes.fetch(ancestor_id) } + [code]
          [code, { id: id, code: code, name_en: name_en, name_ar: name_ar, path: path, ancestor_ids: ancestor_ids, parent_id: parent_id, position: position, depth: depth, active: active }]
        end
        by_id = categories.values.index_by { |entry| entry[:id] }
        children = categories.values.group_by { |entry| entry[:parent_id] }
        ancestors = categories.transform_values { |entry| entry[:ancestor_ids].map { |id| by_id.fetch(id) } }
        descendants = categories.to_h do |code, entry|
          [code, descendants_for(entry[:id], children)]
        end
        { categories: categories, categories_by_id: by_id, children_by_id: children,
          ancestors_by_code: ancestors, descendants_by_code: descendants, roots: children.fetch(nil, []) }
      end

      def descendants_for(id, children)
        children.fetch(id, []).flat_map { |entry| [entry, *descendants_for(entry[:id], children)] }
      end

      def load_locations
        Souq::Location.pluck(:id, :code, :name_en, :name_ar).to_h do |id, code, name_en, name_ar|
          [id, { code: code, name_en: name_en, name_ar: name_ar }]
        end
      end
    end
  end
end
