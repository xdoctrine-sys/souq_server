# frozen_string_literal: true

module Souq
  module Taxonomy
    # Difference between a taxonomy document and the database, produced by the
    # importer for a dry run and for a real import alike (plan T3, design 7.3).
    #
    # Everything is keyed by `code`, never by id. A code missing from the
    # document is deactivated, never deleted, so it always shows up under
    # `deactivated` instead of disappearing silently.
    class Report
      # Created, updated, deactivated and unchanged codes for one section
      # (categories or markets). `deactivated` only lists codes that were still
      # active: an absent code that is already inactive is a no-op.
      class Section
        attr_reader :created, :updated, :deactivated, :unchanged

        def initialize(created: [], updated: [], deactivated: [], unchanged: [])
          @created = created.freeze
          @updated = updated.freeze
          @deactivated = deactivated.freeze
          @unchanged = unchanged.freeze
        end

        def changed?
          created.any? || updated.any? || deactivated.any?
        end

        def to_h
          {
            'created' => created,
            'updated' => updated,
            'deactivated' => deactivated,
            'unchanged' => unchanged,
          }
        end

        def text(label)
          header = "#{label}: #{created.size} created, #{updated.size} updated, " \
                   "#{deactivated.size} deactivated, #{unchanged.size} unchanged"
          lines = updated.map { |code| "  ~ #{label} #{code}" }
          lines.concat(deactivated.map { |code| "  - #{label} #{code} (deactivated)" })
          [header, *lines]
        end
      end

      # Market to category links, held as [market_code, category_code] pairs.
      class Links
        attr_reader :added, :removed

        def initialize(added: [], removed: [])
          @added = added.freeze
          @removed = removed.freeze
        end

        def changed?
          added.any? || removed.any?
        end

        def to_h
          { 'added' => pairs_to_h(added), 'removed' => pairs_to_h(removed) }
        end

        def text
          header = "market links: #{added.size} added, #{removed.size} removed"
          lines = added.map { |market, category| "  + market #{market} -> category #{category}" }
          lines.concat(removed.map { |market, category| "  - market #{market} -> category #{category} (unlinked)" })
          [header, *lines]
        end

        private

        def pairs_to_h(pairs)
          pairs.map { |market, category| { 'market' => market, 'category' => category } }
        end
      end

      attr_reader :dry_run, :categories, :markets, :links
      attr_accessor :taxonomy_version

      def initialize(dry_run:, categories:, markets:, links:, taxonomy_version: nil)
        @dry_run = dry_run
        @categories = categories
        @markets = markets
        @links = links
        @taxonomy_version = taxonomy_version
      end

      def changed?
        categories.changed? || markets.changed? || links.changed?
      end

      def to_h
        {
          'dry_run' => dry_run,
          'changed' => changed?,
          'taxonomy_version' => taxonomy_version,
          'categories' => categories.to_h,
          'markets' => markets.to_h,
          'market_links' => links.to_h,
        }
      end

      def to_text
        header = dry_run ? 'DRY RUN: nothing was written' : "taxonomy_version #{taxonomy_version}"
        lines = [header, *categories.text('category'), *markets.text('market'), *links.text]
        lines << 'no difference' unless changed?
        lines.join("\n")
      end
    end
  end
end
