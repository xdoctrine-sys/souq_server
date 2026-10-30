# frozen_string_literal: true

require 'rails_helper'

# This guard covers every SOUQ table, not one model class.
RSpec.describe 'SOUQ column names' do # rubocop:disable RSpec/DescribeClass
  let(:connection) { ActiveRecord::Base.connection }
  let(:forbidden) { %w(changes attributes errors type hash class save valid frozen transaction connection logger method send object_id display format test) }
  let(:object_methods) { (Object.instance_methods + Object.private_instance_methods + Object.protected_instance_methods).map(&:to_s) }

  def unsafe_columns(table)
    primary_key = connection.primary_key(table)
    connection.columns(table).filter_map do |column|
      name = column.name
      next if name == primary_key

      name if name == 'id' || forbidden.include?(name) ||
              ActiveRecord::Base.dangerous_attribute_method?(name) || object_methods.include?(name)
    end
  end

  it 'guards every SOUQ table against ActiveRecord, STI and Ruby collisions' do
    tables = connection.tables.grep(/\Asouq_/)
    expect(tables).to include('souq_markets', 'souq_categories', 'souq_market_categories', 'souq_audit_logs', 'souq_settings', 'souq_locations', 'souq_listings')
    expect(tables.index_with { |table| unsafe_columns(table) }.reject { |_, columns| columns.empty? }).to be_empty
  end

  it 'uses recorded_changes and can instantiate an audit model' do
    expect(Souq::AuditLog.column_names).to include('recorded_changes')
    expect(Souq::AuditLog.column_names).to_not include('changes')
    expect { Souq::AuditLog.new(recorded_changes: {}) }.to_not raise_error
  end

  it 'detects reserved names on a real PostgreSQL table' do
    connection.create_table(:souq_column_guard_probe) do |table|
      forbidden.each { |name| table.string name }
    end
    expect(unsafe_columns('souq_column_guard_probe')).to match_array(forbidden)
  end
end
