# frozen_string_literal: true

module Souq
  # Process-memory snapshot of the taxonomy tree (categories and locations).
  #
  # The snapshot is keyed by the taxonomy version, which is read from Redis with
  # a single GET so that every process reloads the tree as soon as an
  # administrator bumps the version. T2 owns version increments; T10 only
  # mirrors the bootstrap value the first time the key is missing.
  #
  # The serializer reads categories and locations from this snapshot, so it
  # never issues a SQL query for them.
  class TaxonomyCache
    REDIS_KEY = 'souq:taxonomy:version'
    BOOTSTRAP_VERSION = 1

    MUTEX = Mutex.new

    class << self
      def version
        read_version
      end

      def category(code)
        return if code.nil?

        tree[:categories][code]
      end

      def location_by_id(id)
        return if id.nil?

        tree[:locations_by_id][id]
      end

      # Drops the process-memory snapshot. Used by specs; a version bump is
      # enough to reload in production.
      def reset!
        MUTEX.synchronize do
          @tree = nil
          @tree_version = nil
        end
      end

      private

      def tree
        MUTEX.synchronize do
          current = read_version
          if @tree.nil? || @tree_version != current
            @tree = load_tree
            @tree_version = current
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
