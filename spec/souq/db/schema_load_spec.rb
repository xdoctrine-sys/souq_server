# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# This integration contract exercises Rails tasks in fresh processes.
RSpec.describe 'SOUQ schema restoration in isolated processes' do # rubocop:disable RSpec/DescribeClass
  %w(schema:load prepare).each do |operation|
    it "restores SOUQ objects and Mastodon timestamp_id through db:#{operation}" do
      environment = { 'DB_NAME' => "souq_schema_#{Process.pid}_#{operation.tr(':', '_')}", 'RAILS_ENV' => 'test' }
      commands = operation == 'schema:load' ? ['db:create', 'db:schema:load'] : ['db:prepare']
      begin
        commands.each do |task|
          output, errors, status = Open3.capture3(environment, 'bundle', 'exec', 'rails', task)
          expect(status.success?).to be(true), "#{task} failed:\n#{output}\n#{errors}"
        end
        query = <<~RUBY
          connection = ActiveRecord::Base.connection
          flags = [
            connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'souq_check_category_tree')"),
            connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'souq_categories_tree_check' AND tgdeferrable AND tginitdeferred)"),
            connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'souq_check_location_tree')"),
            connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'souq_locations_tree_check' AND tgdeferrable AND tginitdeferred)"),
            connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'timestamp_id')")
          ]
          attribute_tables = {
            'souq_attribute_definitions' => %w(
              souq_attribute_definition_code souq_attribute_definition_data_type
              souq_attribute_definition_widget souq_attribute_definition_dependency
              souq_attribute_definition_bounds souq_attribute_definition_length
            ),
            'souq_attribute_options' => %w(souq_attribute_option_code),
            'souq_category_attributes' => %w(
              souq_category_attribute_mode souq_category_attribute_config
              souq_category_attribute_condition
            )
          }
          attribute_tables.each do |table, checks|
            flags << (connection.data_source_exists?(table) &&
              (checks - connection.check_constraints(table).map(&:name)).empty?)
          end
          attribute_keys = {
            'souq_attribute_definitions' => [['depends_on_id', 'souq_attribute_definitions', :restrict]],
            'souq_attribute_options' => [['definition_id', 'souq_attribute_definitions', :cascade], ['parent_option_id', 'souq_attribute_options', :restrict]],
            'souq_category_attributes' => [['category_id', 'souq_categories', :cascade], ['definition_id', 'souq_attribute_definitions', :restrict]]
          }
          flags << attribute_keys.all? { |table, expected|
            actual = connection.foreign_keys(table).map { |key| [key.column, key.to_table, key.on_delete] }
            (expected - actual).empty?
          }
          attribute_indexes = {
            'souq_attribute_definitions' => [%w(code), %w(depends_on_id)],
            'souq_attribute_options' => [%w(definition_id code), %w(definition_id position), %w(parent_option_id)],
            'souq_category_attributes' => [%w(category_id definition_id), %w(definition_id)]
          }
          flags << attribute_indexes.all? { |table, expected|
            (expected - connection.indexes(table).map(&:columns)).empty?
          }
          puts flags.to_json
        RUBY
        output, errors, status = Open3.capture3(environment, 'bundle', 'exec', 'rails', 'runner', query)
        expect(status.success?).to be(true), errors
        expect(JSON.parse(output.lines.last)).to eq([true, true, true, true, true, true, true, true, true, true])
      ensure
        Open3.capture3(environment, 'bundle', 'exec', 'rails', 'db:drop')
      end
    end
  end
end
