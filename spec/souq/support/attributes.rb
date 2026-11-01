# frozen_string_literal: true

require_relative 'taxonomy'

RSpec.configure do |config|
  config.before(:suite) do
    require_relative '../fabricators/attribute_fabricators'
  end
end
