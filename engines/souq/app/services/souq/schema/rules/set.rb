# frozen_string_literal: true

module Souq
  module Schema
    module Rules
      # Creates or updates the rule `(category, definition)`. T5 shipped the
      # tables but no write service; T3 and T7 call this one.
      #
      # The outcome is either `changed?` with the new taxonomy version, or an
      # "unchanged" result when the rule already carried exactly these values.
      class Set < Base
        def call(account:, category:, definition:, mode:, required: nil, position: nil, config: {}, condition: nil)
          write(account: account) do
            entry = resolve_category(category)
            definition_row = resolve_definition(definition)
            rule = locked_rule(entry[:id], definition_row.id) || Souq::CategoryAttribute.new(category_id: entry[:id], definition_id: definition_row.id)
            before = rule.persisted? ? snapshot_of(rule) : nil
            action = rule.persisted? ? 'update' : 'create'
            rule.assign_attributes(mode: mode, required: required, position: position,
                                   config: normalize_config(config), condition: normalize_condition(condition))
            changed = rule.new_record? || rule.changed?
            rule.save! if changed
            {
              category_id: entry[:id], category_code: entry[:code], definition_code: definition_row.code,
              rule_id: rule.id, changed: changed, action: action, before: before, after: snapshot_of(rule)
            }
          end
        end
      end
    end
  end
end
