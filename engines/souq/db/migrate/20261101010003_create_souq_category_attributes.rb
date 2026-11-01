# frozen_string_literal: true

class CreateSouqCategoryAttributes < ActiveRecord::Migration[8.1]
  def change
    create_table :souq_category_attributes do |t|
      t.bigint :category_id, null: false
      t.bigint :definition_id, null: false
      t.integer :mode, null: false
      t.boolean :required
      t.integer :position
      t.jsonb :config, null: false, default: {}
      t.jsonb :condition
      t.timestamps
      t.index [:category_id, :definition_id], unique: true
      t.index :definition_id
      t.foreign_key :souq_categories, column: :category_id, on_delete: :cascade
      t.foreign_key :souq_attribute_definitions, column: :definition_id, on_delete: :restrict
      t.check_constraint 'mode BETWEEN 0 AND 2', name: 'souq_category_attribute_mode'
      t.check_constraint "jsonb_typeof(config) = 'object'", name: 'souq_category_attribute_config'
      t.check_constraint "condition IS NULL OR jsonb_typeof(condition) = 'object'", name: 'souq_category_attribute_condition'
    end
  end
end
