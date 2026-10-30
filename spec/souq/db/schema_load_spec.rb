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
            connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'timestamp_id')")
          ]
          puts flags.to_json
        RUBY
        output, errors, status = Open3.capture3(environment, 'bundle', 'exec', 'rails', 'runner', query)
        expect(status.success?).to be(true), errors
        expect(JSON.parse(output.lines.last)).to eq([true, true, true])
      ensure
        Open3.capture3(environment, 'bundle', 'exec', 'rails', 'db:drop')
      end
    end
  end
end
