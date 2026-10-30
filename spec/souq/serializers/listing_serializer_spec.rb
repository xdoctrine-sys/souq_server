# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'

RSpec.describe Souq::REST::ListingSerializer do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:json) { serialized_record_json(listing, described_class) }

  let(:version) { 42 }
  let!(:vehicles) { Fabricate(:souq_category, code: 'vehicles', name_en: 'Vehicles', name_ar: 'مركبات') }
  let!(:cars) { Fabricate(:souq_category, code: 'cars', name_en: 'Cars', name_ar: 'سيارات', parent: vehicles) }
  let(:listing) { Fabricate(:souq_listing, category: cars, category_code: 'cars', title: 'Toyota Land Cruiser 2019', price_mode: 'negotiable', price_minor: 14_500_000, currency: 'QAR') }

  before do
    write_taxonomy_version(version)
    Souq::TaxonomyCache.reset!
  end

  it 'renders the exact section 7.1 shape' do
    expect(json).to eq(
      'id' => listing.id.to_s,
      'title' => 'Toyota Land Cruiser 2019',
      'category' => { 'code' => 'cars', 'name_en' => 'Cars', 'name_ar' => 'سيارات', 'path' => %w(vehicles cars) },
      'price' => { 'mode' => 'negotiable', 'amount' => '145000.00', 'minor' => 14_500_000, 'currency' => 'QAR', 'period' => 'once' },
      'location' => nil,
      'attributes' => [],
      'state' => 'active',
      'taxonomy_version' => version
    )
  end

  it 'exposes only snake_case keys' do
    expect(json.keys).to eq(%w(id title category price location attributes state taxonomy_version))
    expect(json.fetch('price').keys).to eq(%w(mode amount minor currency period))
    expect(json.fetch('category').keys).to eq(%w(code name_en name_ar path))
  end

  it 'renders the location from the taxonomy snapshot' do
    location = Fabricate(:souq_location, code: 'doha', name_en: 'Doha', name_ar: 'الدوحة', kind: 'city', parent: Fabricate(:souq_location, kind: 'region'))
    listing.update!(location: location)

    expect(json.fetch('location')).to eq('code' => 'doha', 'name_en' => 'Doha', 'name_ar' => 'الدوحة')
  end

  it 'nulls amount, minor and currency for unpriced modes while keeping the mode and period' do
    %w(free on_request none).each do |mode|
      unpriced = Fabricate(:souq_listing, category: cars, category_code: 'cars', price_mode: mode, price_minor: nil, currency: nil)
      price = serialized_record_json(unpriced, described_class).fetch('price')

      expect(price).to eq('mode' => mode, 'amount' => nil, 'minor' => nil, 'currency' => nil, 'period' => 'once')
    end
  end
end
