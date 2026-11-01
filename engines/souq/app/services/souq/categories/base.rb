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

      def normalize_reference(reference)
        if reference.is_a?(Category)
          raise NotFoundError, 'category not found' if reference.id.nil?

          Integer(reference.id)
        elsif reference.is_a?(Integer)
          Integer(reference)
        elsif reference.is_a?(String) && reference.match?(/\A[0-9]+\z/)
          Integer(reference, 10)
        else
          reference
        end
      end

      def resolve(reference, optional: false)
        return if reference.nil? && optional

        row = if reference.is_a?(Integer)
                @rows.find { |item| item.id == Integer(reference) }
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
        positions = rows.each_with_index.filter_map { |row, index| [Integer(row.id), index] if row.position != index }
        return if positions.empty?

        sql = <<~SQL.squish
          UPDATE souq_categories
          SET position = ordered.new_position,
              lock_version = lock_version + 1,
              updated_at = CURRENT_TIMESTAMP
          FROM unnest(ARRAY[?]::bigint[], ARRAY[?]::int[]) AS ordered(category_id, new_position)
          WHERE souq_categories.id = ordered.category_id
        SQL
        connection.exec_update(Category.sanitize_sql_array([sql, positions.map(&:first), positions.map(&:last)]), 'SOUQ category order')
      end

      def query_bind(column, value)
        ActiveRecord::Relation::QueryAttribute.new(column.to_s, value, Category.type_for_attribute(column.to_s))
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
