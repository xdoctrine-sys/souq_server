# frozen_string_literal: true

class CreateSouqAttributeDefinitions < ActiveRecord::Migration[8.1]
  def change
    create_table :souq_attribute_definitions do |t|
      t.string :code, null: false
      t.string :name_en, null: false
      t.string :name_ar, null: false
      t.integer :data_type, null: false
      t.string :unit
      t.decimal :min_value
      t.decimal :max_value
      t.integer :max_length
      t.bigint :depends_on_id
      t.integer :filter_widget
      t.boolean :searchable, null: false, default: true
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
      t.index :code, unique: true
      t.index :depends_on_id
      t.foreign_key :souq_attribute_definitions, column: :depends_on_id, on_delete: :restrict
      t.check_constraint "code ~ '^[a-z0-9_]{2,64}$'", name: 'souq_attribute_definition_code'
      t.check_constraint 'data_type BETWEEN 0 AND 6', name: 'souq_attribute_definition_data_type'
      t.check_constraint 'filter_widget IS NULL OR filter_widget BETWEEN 0 AND 4', name: 'souq_attribute_definition_widget'
      t.check_constraint 'depends_on_id IS NULL OR depends_on_id <> id', name: 'souq_attribute_definition_dependency'
      t.check_constraint 'min_value IS NULL OR max_value IS NULL OR min_value <= max_value', name: 'souq_attribute_definition_bounds'
      t.check_constraint 'max_length IS NULL OR max_length > 0', name: 'souq_attribute_definition_length'
    end
  end
end
