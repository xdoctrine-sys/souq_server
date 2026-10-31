# frozen_string_literal: true

module Souq
  # Process-memory snapshot of the taxonomy tree (categories and locations).
  #
  # The snapshot is keyed by the taxonomy version. The version is read from
  # Redis once per render: `snapshot` memoizes the built Snapshot in
  # Souq::Current, which Rails clears at the end of every request and every
  # Sidekiq job, so the snapshot lives exactly one render. Outside those
  # boundaries (console, rake, one-off scripts) nothing clears Souq::Current,
  # so call Souq::Current.reset (or reset! below) to observe a version change.
  #
  # T2 owns version increments; T10 only mirrors the bootstrap value the first
  # time the Redis key is missing.
  #
  # The serializer reads categories and locations from this snapshot, so it
  # never issues a SQL query for them once the snapshot is loaded.
  class TaxonomyCache
    REDIS_KEY = 'souq:taxonomy:version'
    BOOTSTRAP_VERSION = 1

    # Guards only the comparison and the swap of the process tree. The Redis
    # GET and the request snapshot live outside it.
    MUTEX = Mutex.new

    # Immutable, coherent view of the taxonomy for a single version: the
    # category label and the version always come from the same read.
    class Snapshot
      attr_reader :version

      def initialize(version:, categories:, locations_by_id:)
        @version = version
        @categories = deep_freeze(categories)
        @locations_by_id = deep_freeze(locations_by_id)
        freeze
      end

      def category(code)
        return if code.nil?

        @categories[code]
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
        Snapshot.new(version: version, categories: tree[:categories], locations_by_id: tree[:locations_by_id])
      end

      # The Redis GET happens outside the mutex; the mutex only guards the
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
        ::RedisConnection.with do |redis|
          cached = redis.get(REDIS_KEY)
          next cached.to_i if cached

          value = Souq::Setting.first&.taxonomy_version || BOOTSTRAP_VERSION
          redis.set(REDIS_KEY, value)
          value
        end
      end

      def load_tree
        { categories: load_categories, locations_by_id: load_locations }
      end

      def load_categories
        rows = Souq::Category.pluck(:id, :code, :name_en, :name_ar, :ancestor_ids)
        codes = rows.to_h { |id, code, _name_en, _name_ar, _ancestor_ids| [id, code] }

        rows.to_h do |_id, code, name_en, name_ar, ancestor_ids|
          path = ancestor_ids.map { |ancestor_id| codes.fetch(ancestor_id) } + [code]
          [code, { code: code, name_en: name_en, name_ar: name_ar, path: path }]
        end
      end

      def load_locations
        Souq::Location.pluck(:id, :code, :name_en, :name_ar).to_h do |id, code, name_en, name_ar|
          [id, { code: code, name_en: name_en, name_ar: name_ar }]
        end
      end
    end
  end
end
