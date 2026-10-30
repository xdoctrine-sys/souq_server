# frozen_string_literal: true

class CreateSouqSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :souq_settings do |t|
      t.bigint :taxonomy_version, null: false, default: 1
      t.timestamps
      t.check_constraint 'id = 1', name: 'souq_settings_singleton'
      t.check_constraint 'taxonomy_version >= 1', name: 'souq_settings_version'
    end
  end
end
