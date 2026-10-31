# frozen_string_literal: true

module Souq
  module Categories
    class Move < Base
      def call(account:, category:, new_parent:, lock_version: nil, position: nil)
        write(account: account) do
          category = resolve(category)
          parent = resolve(new_parent, optional: true)
          # Verrou optimiste, puis cycle, puis profondeur. T7 fournit toujours la version.
          raise ConflictError, 'stale category' if !lock_version.nil? && lock_version != category.lock_version
          raise CycleError, 'category cannot move below itself' if parent && (parent.id == category.id || parent.ancestor_ids.include?(category.id))

          descendants = @rows.select { |row| row.ancestor_ids.include?(category.id) }
          prefix = parent ? parent.ancestor_ids + [parent.id] : []
          offset = prefix.size - category.depth
          raise DepthError, 'maximum subtree depth is 3' if ([category, *descendants].map(&:depth).max + offset) > 3

          old_parent_id = category.parent_id
          new_rows = siblings(parent&.id, excluding: category.id)
          position = insertion_position(position, new_rows.size)
          next unchanged(category) if old_parent_id == parent&.id && category.position == position

          before = fields(category)
          rewrite(category, parent, prefix, offset, position)
          category.reload
          new_rows.insert(position, category)
          renumber(siblings(old_parent_id, excluding: category.id)) if old_parent_id != parent&.id
          renumber(new_rows)
          finish(category, action: 'move', before: before, descendants_rewritten: offset.zero? && prefix == @old_ancestors ? 0 : descendants.size)
        end
      end

      private

      def rewrite(category, parent, prefix, offset, position)
        @old_ancestors = category.ancestor_ids
        parent_sql = parent ? parent.id.to_s : 'NULL'
        array = "ARRAY[#{prefix.join(',')}]::bigint[]"
        ancestry = "#{array} || ancestor_ids[#{category.depth + 1}:cardinality(ancestor_ids)]"
        connection.execute(<<~SQL.squish)
          UPDATE souq_categories SET
            parent_id = CASE WHEN id = #{category.id} THEN #{parent_sql} ELSE parent_id END,
            position = CASE WHEN id = #{category.id} THEN #{position} ELSE position END,
            ancestor_ids = #{ancestry},
            depth = depth + #{offset},
            lock_version = lock_version + 1,
            updated_at = CURRENT_TIMESTAMP
          WHERE (id = #{category.id} OR ancestor_ids @> ARRAY[#{category.id}]::bigint[])
            AND (ancestor_ids IS DISTINCT FROM (#{ancestry})
              OR (id = #{category.id} AND (parent_id IS DISTINCT FROM #{parent_sql} OR position <> #{position})))
        SQL
      end
    end
  end
end
