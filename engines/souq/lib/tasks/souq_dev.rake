# frozen_string_literal: true

require_relative '../souq/demo_seed'

namespace :souq do
  namespace :dev do
    desc 'Create a small SOUQ demo taxonomy outside production'
    task demo_seed: :environment do
      Souq::DemoSeed.run!
    end
  end
end
