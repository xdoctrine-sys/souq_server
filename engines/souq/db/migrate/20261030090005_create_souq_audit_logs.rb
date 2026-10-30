# frozen_string_literal: true

class CreateSouqAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :souq_audit_logs do |t|
      t.bigint :account_id
      t.string :action, null: false
      t.string :target_type, null: false
      t.bigint :target_id, null: false
      t.jsonb :recorded_changes, null: false, default: {}
      t.timestamps
      t.index :account_id
      t.index [:target_type, :target_id]
      t.foreign_key :accounts, on_delete: :nullify
    end
  end
end
