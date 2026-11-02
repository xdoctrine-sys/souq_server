# frozen_string_literal: true

module Souq
  module Schema
    module Rules
      # Removes the rule `(category, definition)`. Descendants are revalidated
      # afterwards, so an `override` left orphan by the removal is reported
      # instead of silently losing its attribute.
      class Remove < Base
        def call(account:, category:, definition:)
          write(account: account) do
            entry = resolve_category(category)
            definition_row = resolve_definition(definition)
            rule = locked_rule(entry[:id], definition_row.id)

            if rule.nil?
              { category_id: entry[:id], category_code: entry[:code], definition_code: definition_row.code,
                rule_id: nil, changed: false, action: nil, before: nil, after: nil }
            else
              before = snapshot_of(rule)
              rule_id = rule.id
              rule.destroy!
              { category_id: entry[:id], category_code: entry[:code], definition_code: definition_row.code,
                rule_id: rule_id, changed: true, action: 'deactivate', before: before, after: nil }
            end
          end
        end
      end
    end
  end
end
