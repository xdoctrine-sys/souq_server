# frozen_string_literal: true

module Souq
  module Taxonomy
    # Applies a validated taxonomy document to the database (plan T3, design 7.3).
    #
    # Rules:
    # - rows are matched by `code`, never by id, so ids are never reused or
    #   guessed between two servers;
    # - a code absent from the document is deactivated, never deleted, and its
    #   links are the only thing the import may remove;
    # - everything runs in one transaction under the category tree advisory
    #   lock, with a single taxonomy_version increment and one audit line, so a
    #   failure leaves the previous version untouched;
    # - `dry_run: true` computes and returns the same report, then rolls the
    #   transaction back, so a dry run can never write.
    class Importer
      CATEGORY_FIELDS = %w(name_en name_ar description_en description_ar icon cover_url color hashtag hashtag_ar position active listable).freeze
      MARKET_FIELDS = %w(name_en name_ar description_en description_ar icon cover_url color position active).freeze

      def self.call(...)
        new.call(...)
      end

      def call(document:, account:, dry_run: false)
        raise ValidationError, { account: ['must be a persisted account'] } unless account.is_a?(::Account) && account.persisted?

        report = nil
        ApplicationRecord.transaction do |transaction|
          @transaction = transaction
          @document = document
          lock
          load_existing
          report = build_report(dry_run)
          if dry_run
            raise ActiveRecord::Rollback
          elsif report.changed?
            @report = report
            apply(account)
            @transaction.after_commit { Current.taxonomy_snapshot = nil }
          end
        end
        report
      end

      private

      def connection
        Category.connection
      end

      # The trigger installs the same lock at commit (design 8.1): taking it here
      # serializes the whole import against every category service and against a
      # concurrent import.
      def lock
        connection.execute("SELECT pg_advisory_xact_lock(hashtext('souq_categories_tree'))")
      end

      def load_existing
        @existing_categories = Category.order(:id).lock.index_by(&:code)
        @existing_markets = Market.order(:id).lock.index_by(&:code)
        @category_code_by_id = @existing_categories.values.to_h { |row| [row.id, row.code] }
        @links = MarketCategory.order(:market_id, :position, :id).to_a
      end

      def build_report(dry_run)
        Report.new(dry_run: dry_run, categories: category_section, markets: market_section, links: link_section)
      end

      def category_section
        created = []
        updated = []
        unchanged = []
        @document.categories.each do |entry|
          row = @existing_categories[entry['code']]
          if row.nil?
            created << entry['code']
          elsif category_changed?(row, entry)
            updated << entry['code']
          else
            unchanged << entry['code']
          end
        end
        Report::Section.new(created: created, updated: updated, deactivated: deactivated_codes(@existing_categories, @document.category_codes), unchanged: unchanged)
      end

      def market_section
        created = []
        updated = []
        unchanged = []
        @document.markets.each do |entry|
          row = @existing_markets[entry['code']]
          if row.nil?
            created << entry['code']
          elsif market_changed?(row, entry)
            updated << entry['code']
          else
            unchanged << entry['code']
          end
        end
        Report::Section.new(created: created, updated: updated, deactivated: deactivated_codes(@existing_markets, @document.market_codes), unchanged: unchanged)
      end

      def link_section
        added = []
        removed = []
        @document.markets.each do |entry|
          row = @existing_markets[entry['code']]
          current = links_for(row.id).index_by { |link| @category_code_by_id[link.category_id] } if row
          desired = entry['categories']
          desired.each { |code| added << [entry['code'], code] unless current&.key?(code) }
          current&.each_key { |code| removed << [entry['code'], code] unless desired.include?(code) }
        end
        Report::Links.new(added: added, removed: removed)
      end

      def deactivated_codes(rows, desired_codes)
        desired = desired_codes.to_set
        rows.values.select { |row| row.active? && !desired.include?(row.code) }.map(&:code)
      end

      # The parent is compared as a document code, not as an id: a parent that
      # the same run is about to create has no id yet, so an id comparison
      # would report a move as unchanged in the dry run while the import
      # actually applies it.
      def category_changed?(row, entry)
        @category_code_by_id[row.parent_id] != entry['parent_code'] ||
          CATEGORY_FIELDS.any? { |field| row.public_send(field) != entry[field] }
      end

      def market_changed?(row, entry)
        MARKET_FIELDS.any? { |field| row.public_send(field) != entry[field] }
      end

      def links_for(market_id)
        @links.select { |link| link.market_id == market_id }
      end

      def apply(account)
        write_categories
        write_markets
        write_links
        version = increment_version
        @report.taxonomy_version = version
        audit(account, version)
      end

      # Parents always come before their children because the document tree is
      # complete and validated, and a code path sorts parents first. The sort is
      # made stable on the document order so the import is reproducible.
      def write_categories
        @rows = {}
        ordered_categories.each do |entry|
          row = @existing_categories[entry['code']]
          parent = entry['parent_code'] ? @rows.fetch(entry['parent_code']) : nil
          attributes = category_attributes(entry)
          if row
            reparent(row, parent) if row.parent_id != parent&.id
            row.assign_attributes(attributes)
            row.save! if row.changed?
          else
            row = Category.create!(attributes.merge('code' => entry['code'], 'parent' => parent))
          end
          @rows[entry['code']] = row
        end
        deactivate_absent_categories
      end

      def ordered_categories
        @ordered_categories ||= begin
          depths = document_depths
          @document.categories.each_with_index.sort_by { |entry, index| [depths.fetch(entry['code']), index] }.map(&:first)
        end
      end

      # The document is validated: parents are known and no cycle exists.
      def document_depths
        by_code = @document.categories.index_by { |entry| entry['code'] }
        @document.categories.to_h do |entry|
          depth = 0
          parent = entry['parent_code']
          while parent
            depth += 1
            parent = by_code.fetch(parent)['parent_code']
          end
          [entry['code'], depth]
        end
      end

      # parent_id, ancestor_ids and depth change together: the deferred trigger
      # only checks the final rows at commit, so children are rewritten after
      # their parent in the same transaction.
      def reparent(row, parent)
        row.parent = parent
        row.ancestor_ids = parent ? parent.ancestor_ids + [parent.id] : []
        row.depth = row.ancestor_ids.size
      end

      def category_attributes(entry)
        CATEGORY_FIELDS.index_with { |field| entry[field] }
      end

      def deactivate_absent_categories
        desired = @document.category_codes.to_set
        @existing_categories.each_value do |row|
          row.update!(active: false) unless desired.include?(row.code) || !row.active?
        end
      end

      def write_markets
        @market_rows = {}
        @document.markets.each do |entry|
          row = @existing_markets[entry['code']]
          attributes = MARKET_FIELDS.index_with { |field| entry[field] }
          if row
            row.assign_attributes(attributes)
            row.save! if row.changed?
          else
            row = Market.create!(attributes.merge('code' => entry['code']))
          end
          @market_rows[entry['code']] = row
        end
        deactivate_absent_markets
      end

      def deactivate_absent_markets
        desired = @document.market_codes.to_set
        @existing_markets.each_value do |row|
          row.update!(active: false) unless desired.include?(row.code) || !row.active?
        end
      end

      # The document is authoritative for the curated market -> category list:
      # a missing link is created, a stale one is unlinked. Both sides are
      # categories, never markets, so no category row is ever deleted.
      def write_links
        @document.markets.each do |entry|
          market = @market_rows.fetch(entry['code'])
          current = links_for(market.id).index_by { |link| @category_code_by_id[link.category_id] }
          entry['categories'].each_with_index do |code, position|
            link = current.delete(code)
            if link
              link.update!(position: position) if link.position != position
            else
              MarketCategory.create!(market: market, category: @rows.fetch(code), position: position)
            end
          end
          current.each_value(&:destroy!)
        end
      end

      def increment_version
        raw = connection.select_value(<<~SQL.squish)
          UPDATE souq_settings SET taxonomy_version = taxonomy_version + 1,
            updated_at = CURRENT_TIMESTAMP
          WHERE id = 1 RETURNING taxonomy_version
        SQL
        return Integer(raw) unless raw.nil?

        Setting.create!(id: 1, taxonomy_version: TaxonomyCache::BOOTSTRAP_VERSION + 1).taxonomy_version
      end

      def audit(account, version)
        AuditLog.create!(
          account: account, action: 'import', target_type: 'Souq::Setting', target_id: 1,
          recorded_changes: @report.to_h.except('dry_run').merge('taxonomy_version' => version)
        )
      end
    end
  end
end
