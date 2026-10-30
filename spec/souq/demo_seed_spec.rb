# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('engines', 'souq', 'lib', 'souq', 'demo_seed')

RSpec.describe Souq::DemoSeed do
  it 'creates the demo taxonomy and locations idempotently' do
    2.times { described_class.run! }
    vehicles = Souq::Category.find_by!(code: 'vehicles')
    cars = Souq::Category.find_by!(code: 'cars')
    expect(cars.parent).to eq(vehicles)
    expect(cars.ancestor_ids).to eq([vehicles.id])
    expect(Souq::Market.find_by!(code: 'motors').categories).to eq([vehicles])
    expect(Souq::Category.count).to eq(2)
    expect(Souq::Market.count).to eq(1)
    region = Souq::Location.find_by!(code: 'demo_region')
    city = Souq::Location.find_by!(code: 'demo_city')
    expect(region).to be_region
    expect(city).to be_city
    expect(city.parent).to eq(region)
    expect(city.ancestor_ids).to eq([region.id])
    expect(Souq::Location.count).to eq(2)
  end

  it 'refuses the production environment before accessing the database' do
    expect { described_class.run!(environment: 'production') }
      .to raise_error(ArgumentError, 'SOUQ demo seed is forbidden in production')
  end
end
