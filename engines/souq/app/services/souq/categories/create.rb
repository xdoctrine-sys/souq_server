# frozen_string_literal: true

module Souq
  module Categories
    class Create < Base
      FIELDS = %i(code name_en name_ar description_en description_ar icon cover_url color hashtag hashtag_ar active listable).freeze

      def call(account:, parent: nil, position: nil, **attributes)
        write(account: account) do
          unknown = attributes.keys - FIELDS
          raise(ValidationError, unknown.index_with { ['cannot be supplied'] }) if unknown.any?

          parent = resolve(parent, optional: true)
          raise DepthError, 'maximum category depth is 3' if parent && parent.depth >= 3

          rows = siblings(parent&.id)
          position = insertion_position(position, rows.size)
          category = Category.create!(**attributes, parent: parent, position: position)
          rows.insert(position, category)
          renumber(rows)
          finish(category, action: 'create', before: nil)
        end
      end
    end
  end
end
