# frozen_string_literal: true

module Souq
  module Categories
    class Move < Base
      def call(account:, category:, new_parent:, lock_version: nil, position: nil)
        category = normalize_reference(category)
        new_parent = normalize_reference(new_parent)
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
        sql = <<~SQL.squish
          WITH movement AS (
            SELECT CAST($1 AS bigint) AS node_id,
                   CAST($2 AS bigint) AS target_parent_id,
                   CAST($3 AS int) AS target_position,
                   CAST($4 AS int) AS depth_offset,
                   CAST($5 AS bigint[]) AS ancestor_prefix,
                   CAST($6 AS int) AS suffix_start
          )
          UPDATE souq_categories SET
            parent_id = CASE WHEN id = movement.node_id THEN movement.target_parent_id ELSE parent_id END,
            position = CASE WHEN id = movement.node_id THEN movement.target_position ELSE position END,
            ancestor_ids = movement.ancestor_prefix || ancestor_ids[movement.suffix_start:cardinality(ancestor_ids)],
            depth = depth + movement.depth_offset,
            lock_version = lock_version + 1,
            updated_at = CURRENT_TIMESTAMP
          FROM movement
          WHERE (id = movement.node_id OR ancestor_ids @> ARRAY[movement.node_id]::bigint[])
            AND (ancestor_ids IS DISTINCT FROM (movement.ancestor_prefix || ancestor_ids[movement.suffix_start:cardinality(ancestor_ids)])
              OR (id = movement.node_id AND (parent_id IS DISTINCT FROM movement.target_parent_id OR position <> movement.target_position)))
        SQL
        binds = [
          query_bind(:id, Integer(category.id)),
          query_bind(:parent_id, parent ? Integer(parent.id) : nil),
          query_bind(:position, Integer(position)),
          query_bind(:position, Integer(offset)),
          query_bind(:ancestor_ids, prefix.map { |id| Integer(id) }),
          query_bind(:position, Integer(category.depth) + 1),
        ]
        connection.exec_update(sql, 'SOUQ category subtree', binds)
      end
    end
  end
end
