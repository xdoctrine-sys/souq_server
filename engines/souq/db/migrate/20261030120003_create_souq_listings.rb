# frozen_string_literal: true

class CreateSouqListings < ActiveRecord::Migration[8.1]
  def change
    create_table :souq_listings do |t|
      t.bigint :status_id, null: false
      t.bigint :account_id, null: false
      t.bigint :category_id
      t.string :category_code, null: false
      t.boolean :local, null: false
      t.string :title, limit: 140, null: false
      t.integer :price_mode, null: false
      t.bigint :price_minor
      t.column :currency, 'char(3)'
      t.integer :price_period, null: false, default: 0
      t.integer :sale_mode, null: false, default: 0
      t.bigint :location_id
      t.jsonb :attribute_values, null: false, default: {}
      t.integer :state, null: false, default: 0
      t.datetime :published_at, null: false
      t.datetime :expires_at
      t.datetime :sold_at
      t.integer :remote_payload_version
      t.timestamps
      t.index :status_id, unique: true
      t.index [:category_id, :state, :published_at], order: { published_at: :desc }, name: 'index_souq_listings_category_recent'
      t.index [:category_id, :state, :price_minor, :status_id], where: 'price_minor IS NOT NULL', name: 'index_souq_listings_category_price'
      t.index [:account_id, :published_at], order: { published_at: :desc }, name: 'index_souq_listings_account_recent'
      t.index :location_id
      t.index :attribute_values, using: :gin, opclass: :jsonb_path_ops
      t.foreign_key :statuses, on_delete: :cascade
      t.foreign_key :accounts, on_delete: :cascade
      t.foreign_key :souq_categories, column: :category_id, on_delete: :restrict
      t.foreign_key :souq_locations, column: :location_id, on_delete: :restrict
      t.check_constraint 'price_mode BETWEEN 0 AND 4', name: 'souq_listing_price_mode'
      t.check_constraint 'price_period BETWEEN 0 AND 4', name: 'souq_listing_price_period'
      t.check_constraint 'sale_mode BETWEEN 0 AND 1', name: 'souq_listing_sale_mode'
      t.check_constraint 'state BETWEEN 0 AND 4', name: 'souq_listing_state'
      t.check_constraint 'char_length(title) BETWEEN 1 AND 140', name: 'souq_listing_title'
      t.check_constraint "jsonb_typeof(attribute_values) = 'object'", name: 'souq_listing_attribute_object'
      t.check_constraint 'price_minor IS NULL OR price_minor > 0', name: 'souq_listing_positive_price'
      t.check_constraint "currency IS NULL OR currency ~ '^[A-Z]{3}$'", name: 'souq_listing_currency'
      t.check_constraint '(price_mode IN (0, 1) AND price_minor IS NOT NULL AND price_minor > 0 AND currency IS NOT NULL) OR (price_mode IN (2, 3, 4) AND price_minor IS NULL AND currency IS NULL)', name: 'souq_listing_price_consistency'
      t.check_constraint 'price_period = 0 OR price_mode IN (0, 1)', name: 'souq_listing_period_consistency'
    end
  end
end
