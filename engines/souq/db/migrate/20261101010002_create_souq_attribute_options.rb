# frozen_string_literal: true

class CreateSouqAttributeOptions < ActiveRecord::Migration[8.1]
  def change
    create_table :souq_attribute_options do |t|
      t.bigint :definition_id, null: false
      t.string :code, null: false
      t.bigint :parent_option_id
      t.string :name_en, null: false
      t.string :name_ar, null: false
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
      t.index [:definition_id, :code], unique: true
      t.index [:definition_id, :position]
      t.index :parent_option_id
      t.foreign_key :souq_attribute_definitions, column: :definition_id, on_delete: :cascade
      t.foreign_key :souq_attribute_options, column: :parent_option_id, on_delete: :restrict
      t.check_constraint "code ~ '^[a-z0-9_]{2,64}$'", name: 'souq_attribute_option_code'
    end
  end
end
