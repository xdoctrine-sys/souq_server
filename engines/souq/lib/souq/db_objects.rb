# frozen_string_literal: true

module Souq
  module DbObjects
    SQL = <<~SQL
      CREATE OR REPLACE FUNCTION souq_check_category_tree() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        category souq_categories%ROWTYPE;
        expected bigint[];
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtext('souq_categories_tree'));
        -- Read the final row, not the intermediate NEW image queued by the trigger.
        SELECT * INTO category FROM souq_categories WHERE id = NEW.id;
        IF NOT FOUND THEN
          RETURN NULL;
        END IF;
        IF category.parent_id IS NULL THEN
          expected := '{}'::bigint[];
        ELSE
          SELECT ancestor_ids || id INTO expected
          FROM souq_categories WHERE id = category.parent_id;
        END IF;
        IF category.ancestor_ids IS DISTINCT FROM expected THEN
          RAISE EXCEPTION 'SOUQ category ancestry is inconsistent'
            USING ERRCODE = '23514', CONSTRAINT = 'souq_categories_tree_check';
        END IF;
        IF EXISTS (
          SELECT 1 FROM souq_categories
          WHERE parent_id = category.id
            AND ancestor_ids IS DISTINCT FROM (category.ancestor_ids || category.id)
        ) THEN
          RAISE EXCEPTION 'SOUQ category children have inconsistent ancestry'
            USING ERRCODE = '23514', CONSTRAINT = 'souq_categories_tree_check';
        END IF;
        RETURN NULL;
      END;
      $$;
      DROP TRIGGER IF EXISTS souq_categories_tree_check ON souq_categories;
      CREATE CONSTRAINT TRIGGER souq_categories_tree_check
      AFTER INSERT OR UPDATE ON souq_categories
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
      EXECUTE FUNCTION souq_check_category_tree();
    SQL

    def self.install!(connection = ActiveRecord::Base.connection)
      connection.execute(SQL) if connection.data_source_exists?('souq_categories')
    end

    def self.uninstall!(connection = ActiveRecord::Base.connection)
      connection.execute('DROP TRIGGER IF EXISTS souq_categories_tree_check ON souq_categories')
      connection.execute('DROP FUNCTION IF EXISTS souq_check_category_tree()')
    end

    module SchemaLoader
      def load_schema(...)
        super
        Souq::DbObjects.install!
      end
    end
  end
end
