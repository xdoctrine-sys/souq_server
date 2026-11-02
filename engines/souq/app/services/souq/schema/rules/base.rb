# frozen_string_literal: true

module Souq
  module Schema
    module Rules
      # Shared write discipline for the attribute-rule services (design
      # section 3.4, prompt section 3). One transaction takes the very same
      # advisory lock as the category tree, so a rule write and a T2 Move
      # cannot interleave. The whole subtree is revalidated with the change
      # applied before anything is committed: a single bad descendant rolls the
      # rule, the version bump and the audit row back together.
      class Base
        Result = Struct.new(:category_code, :definition_code, :changed, :taxonomy_version, keyword_init: true) do
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
            @account = account
            @transaction = transaction
            load_categories
            outcome = yield
            validate_subtree!(outcome) if outcome[:changed]
            finish(outcome)
          end
        rescue ActiveRecord::RecordInvalid => e
          raise ValidationError, e.record.errors.to_hash
        rescue ActiveRecord::StatementInvalid => e
          raise ValidationError, { rule: ['database constraint rejected the operation'] } if e.cause.is_a?(PG::IntegrityConstraintViolation)

          raise
        end

        def connection
          Souq::CategoryAttribute.connection
        end

        # Read under the advisory lock: the resolution of every descendant
        # needs the full ancestry, so the whole tree is read once, in memory.
        def load_categories
          @rows = Souq::Category.order(:id).pluck(:id, :code, :ancestor_ids)
          @entries_by_code = Resolve.categories_from_rows(@rows)
          @entries_by_id = @entries_by_code.values.index_by { |entry| entry[:id] }
        end

        def resolve_category(reference)
          entry =
            case reference
            when Souq::Category then @entries_by_id[reference.id]
            when Integer then @entries_by_id[reference]
            else @entries_by_code[reference.to_s]
            end
          raise NotFoundError, 'category not found' if entry.nil?

          entry
        end

        def resolve_definition(reference)
          definition = reference.is_a?(Souq::AttributeDefinition) ? reference : Souq::AttributeDefinition.find_by(code: reference.to_s)
          raise NotFoundError, 'attribute definition not found' if definition.nil?

          definition
        end

        # Re-reads the rule row under a FOR NO KEY UPDATE lock, the same
        # discipline as the tree services. A missing row means an insert.
        def locked_rule(category_id, definition_id)
          Souq::CategoryAttribute.lock('FOR NO KEY UPDATE').find_by(category_id: category_id, definition_id: definition_id)
        end

        # Replays the resolution for the changed category and each descendant
        # with the rule change already visible in the transaction. A single
        # issue aborts the whole operation.
        def validate_subtree!(outcome)
          catalog = Souq::Schema::Catalog.load
          categories = Resolve.categories_from_rows(@rows)
          issues = subtree_entries(outcome[:category_id], categories).flat_map do |entry|
            Resolve.for_category(catalog: catalog, categories: categories, category: entry).issues
          end
          raise RuleError, issues if issues.any?
        end

        def subtree_entries(category_id, categories)
          codes = @rows.filter_map do |id, code, ancestor_ids|
            code if id == category_id || ancestor_ids.include?(category_id)
          end
          codes.map { |code| categories.fetch(code) }
        end

        def finish(outcome)
          return unchanged(outcome) unless outcome[:changed]

          version = connection.select_value(<<~SQL.squish)
            UPDATE souq_settings SET taxonomy_version = taxonomy_version + 1,
              updated_at = CURRENT_TIMESTAMP
            WHERE id = 1 RETURNING taxonomy_version
          SQL
          version ||= Setting.create!(id: 1, taxonomy_version: TaxonomyCache::BOOTSTRAP_VERSION + 1).taxonomy_version
          AuditLog.create!(
            account: @account, action: outcome[:action], target_type: 'Souq::CategoryAttribute',
            target_id: outcome[:rule_id], recorded_changes: { before: outcome[:before], after: outcome[:after] }
          )
          @transaction.after_commit { Current.taxonomy_snapshot = nil }
          Result.new(category_code: outcome[:category_code], definition_code: outcome[:definition_code],
                     changed: true, taxonomy_version: version)
        end

        def unchanged(outcome)
          Result.new(category_code: outcome[:category_code], definition_code: outcome[:definition_code], changed: false)
        end

        def normalize_config(config)
          return {} if config.nil?

          config.to_h { |key, value| [key.to_s, value] }
        end

        def normalize_condition(condition)
          return if condition.nil?

          condition.to_h { |key, value| [key.to_s, value] }
        end

        # The audit payload always carries the same keys, so a reader never has
        # to parse free text.
        def snapshot_of(rule)
          { mode: rule.mode, required: rule.required, position: rule.position, config: rule.config, condition: rule.condition }
        end
      end
    end
  end
end
