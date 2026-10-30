# frozen_string_literal: true

class CreateSouqMarketCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :souq_market_categories do |t|
      t.bigint :market_id, null: false
      t.bigint :category_id, null: false
      t.integer :position, null: false, default: 0
      t.string :cover_url
      t.boolean :featured, null: false, default: false
      t.timestamps
      t.index [:market_id, :category_id], unique: true
      t.index [:market_id, :position]
      t.foreign_key :souq_markets, column: :market_id, on_delete: :cascade
      t.foreign_key :souq_categories, column: :category_id, on_delete: :cascade
    end
  end
end
