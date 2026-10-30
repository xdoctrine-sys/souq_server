# frozen_string_literal: true

RSpec.configure do |config|
  config.before(:suite) do
    # Preserve Fabrication's upstream definitions and load after upstream seeds.
    Fabrication.manager.load_definitions if Fabrication.manager.empty?
    require_relative '../fabricators/taxonomy_fabricators'
  end
end
