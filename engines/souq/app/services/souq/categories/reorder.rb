# frozen_string_literal: true

module Souq
  module Categories
    class Reorder < Base
      def call(account:, parent:, ordered_ids:)
        write(account: account) do
          parent = resolve(parent, optional: true)
          rows = siblings(parent&.id)
          ids = rows.map(&:id)
          raise ConflictError, 'ordered_ids must contain every current child exactly once' unless ordered_ids.is_a?(Array) && ordered_ids.all?(Integer) && ordered_ids.sort == ids.sort
          next unchanged(parent) if ordered_ids == ids

          ordered = ordered_ids.map { |id| rows.find { |row| row.id == id } }
          target = ordered.first
          before = fields(target)
          renumber(ordered)
          finish(target, action: 'reorder', before: before)
        end
      end
    end
  end
end
