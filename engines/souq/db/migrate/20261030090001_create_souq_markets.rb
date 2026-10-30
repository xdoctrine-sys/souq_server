# frozen_string_literal: true

class CreateSouqMarkets < ActiveRecord::Migration[8.1]
  def change
    create_table :souq_markets do |t|
      t.string :code, null: false
      t.string :name_en, null: false
      t.string :name_ar, null: false
      t.text :description_en
      t.text :description_ar
      t.string :icon
      t.string :cover_url
      t.string :color
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
      t.index :code, unique: true
    end
  end
end
