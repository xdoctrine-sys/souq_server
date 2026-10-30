# frozen_string_literal: true

class CreateSouqCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :souq_categories do |t|
      t.bigint :parent_id
      t.bigint :ancestor_ids, array: true, null: false, default: []
      t.integer :depth, limit: 2, null: false, default: 0
      t.string :code, null: false
      t.string :name_en, null: false
      t.string :name_ar, null: false
      t.text :description_en
      t.text :description_ar
      t.string :icon
      t.string :cover_url
      t.string :color
      t.string :hashtag
      t.string :hashtag_ar
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.boolean :listable, null: false, default: true
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index :code, unique: true
      t.index [:parent_id, :position]
      t.index :ancestor_ids, using: :gin
      t.index :hashtag
      t.foreign_key :souq_categories, column: :parent_id, on_delete: :restrict
      t.check_constraint 'parent_id IS NULL OR parent_id <> id', name: 'souq_category_not_own_parent'
      t.check_constraint 'NOT (id = ANY(ancestor_ids))', name: 'souq_category_not_own_ancestor'
      t.check_constraint 'depth = cardinality(ancestor_ids) AND depth <= 3', name: 'souq_category_depth'
      t.check_constraint '(parent_id IS NULL) = (cardinality(ancestor_ids) = 0)', name: 'souq_category_root'
      t.check_constraint 'parent_id IS NULL OR ancestor_ids[cardinality(ancestor_ids)] = parent_id', name: 'souq_category_last_ancestor'
    end
  end
end
