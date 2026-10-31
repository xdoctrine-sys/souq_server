# frozen_string_literal: true

module Souq
  module Categories
    class Base
      Result = Struct.new(:category, :changed, :taxonomy_version, keyword_init: true) do
        alias_method :changed?, :changed
      end

      def self.call(...)
        new.call(...)
      end

      private

      def write(account:)
        raise ValidationError, { account: ['must be a persisted account'] } unless account.is_a?(::Account) && account.persisted?

        ApplicationRecord.transaction do |transaction|
          connection.execute("SELECT pg_advisory_xact_lock(hashtext('souq_categories_tree'))")
          @rows = Category.order(:id).lock.to_a
          @account = account
          @transaction = transaction
          yield
        end
      rescue ActiveRecord::RecordInvalid => e
        raise ValidationError, e.record.errors.to_hash
      rescue ActiveRecord::StaleObjectError
        raise ConflictError, 'stale category'
      rescue ActiveRecord::StatementInvalid => e
        raise ValidationError, { tree: ['database constraint rejected the operation'] } if e.cause.is_a?(PG::IntegrityConstraintViolation)

        raise
      end

      def connection
        Category.connection
      end

      def resolve(reference, optional: false)
        return if reference.nil? && optional

        row = if reference.is_a?(Category)
                @rows.find { |item| item.id == reference.id }
              elsif reference.is_a?(Integer) || reference.to_s.match?(/\A[0-9]+\z/)
                @rows.find { |item| item.id == reference.to_i }
              else
                @rows.find { |item| item.code == reference }
              end
        row || raise(NotFoundError, 'category not found')
      end

      def siblings(parent_id, excluding: nil)
        @rows.select { |row| row.parent_id == parent_id && row.id != excluding }.sort_by { |row| [row.position, row.id] }
      end

      def insertion_position(position, size)
        return size if position.nil?

        raise ValidationError, { position: ['must be an integer within the sibling list'] } unless position.is_a?(Integer) && position.between?(0, size)

        position
      end

      def renumber(rows)
        positions = rows.each_with_index.filter_map { |row, index| [row.id, index] if row.position != index }
        return if positions.empty?

        cases = positions.map { |id, index| "WHEN #{id} THEN #{index}" }.join(' ')
        connection.execute(<<~SQL.squish)
          UPDATE souq_categories
          SET position = CASE id #{cases} END,
              lock_version = lock_version + 1,
              updated_at = CURRENT_TIMESTAMP
          WHERE id IN (#{positions.map(&:first).join(',')})
        SQL
      end

      def fields(row)
        row&.attributes&.slice('parent_id', 'position', 'depth')
      end

      def finish(category, action:, before:, descendants_rewritten: 0)
        version = connection.select_value(<<~SQL.squish)
          UPDATE souq_settings SET taxonomy_version = taxonomy_version + 1,
            updated_at = CURRENT_TIMESTAMP
          WHERE id = 1 RETURNING taxonomy_version
        SQL
        version ||= Setting.create!(id: 1, taxonomy_version: TaxonomyCache::BOOTSTRAP_VERSION + 1).taxonomy_version
        category.reload
        AuditLog.create!(
          account: @account, action: action, target_type: 'Souq::Category', target_id: category.id,
          recorded_changes: { before: before, after: fields(category), descendants_rewritten: descendants_rewritten }
        )
        @transaction.after_commit { Current.taxonomy_snapshot = nil }
        Result.new(category: category, changed: true, taxonomy_version: version)
      end

      def unchanged(category)
        Result.new(category: category, changed: false)
      end
    end
  end
end
