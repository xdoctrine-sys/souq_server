# frozen_string_literal: true

require 'rails_helper'
require_relative 'support/taxonomy'
require_relative 'support/taxonomy_cache'

RSpec.describe Souq::TaxonomyCache do
  let(:version) { 7 }
  let!(:vehicles) { Fabricate(:souq_category, code: 'vehicles', name_en: 'Vehicles', name_ar: 'مركبات') }
  let!(:cars) { Fabricate(:souq_category, code: 'cars', name_en: 'Cars', name_ar: 'سيارات', parent: vehicles) }
  let!(:qatar) { Fabricate(:souq_location, code: 'qatar', name_en: 'Qatar', name_ar: 'قطر', kind: 'region') }
  let!(:doha) { Fabricate(:souq_location, code: 'doha', name_en: 'Doha', name_ar: 'الدوحة', kind: 'city', parent: qatar) }

  before do
    write_taxonomy_version(version)
    described_class.reset!
  end

  # Counts SQL statements issued while the block runs, ignoring schema queries.
  def queries_during(&block)
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    statements
  end

  def render_listing(listing)
    JSON.parse(Souq::REST::ListingSerializer.new(listing).to_json)
  end

  it 'reads the version from the Redis key' do
    expect(described_class.version).to eq(version)
  end

  it 'serves a category from memory without a SQL query' do
    described_class.category('cars') # warms the snapshot

    statements = queries_during { described_class.category('cars') }

    expect(statements).to be_empty
  end

  it 'serves a location from memory without a SQL query' do
    described_class.location_by_id(doha.id) # warms the snapshot

    statements = queries_during { described_class.location_by_id(doha.id) }

    expect(statements).to be_empty
  end

  it 'keeps the snapshot when the version does not change' do
    described_class.category('cars')
    cars.update!(name_en: 'Voitures')

    statements = queries_during { expect(described_class.category('cars')).to include(name_en: 'Cars') }

    expect(statements).to be_empty
  end

  it 'reloads the snapshot when the version changes' do
    expect(described_class.category('cars')).to include(name_en: 'Cars')

    cars.update!(name_en: 'Voitures')
    write_taxonomy_version(version + 1)
    Souq::Current.reset # a version change is observed at the next request boundary

    reloaded = nil
    statements = queries_during { reloaded = described_class.category('cars') }

    expect(reloaded).to include(name_en: 'Voitures')
    expect(statements).to_not be_empty
    expect(described_class.version).to eq(version + 1)
  end

  it 'serves one coherent version inside a single Souq::Current scope' do
    listing = Fabricate(:souq_listing, category: cars, category_code: 'cars')

    first = render_listing(listing)
    expect(first.fetch('category')).to include('code' => 'cars', 'name_en' => 'Cars')
    expect(first.fetch('taxonomy_version')).to eq(version)

    cars.update!(name_en: 'Voitures')
    write_taxonomy_version(version + 1)

    second = render_listing(listing)
    expect(second.fetch('category')).to include('name_en' => 'Cars')
    expect(second.fetch('taxonomy_version')).to eq(version)

    Souq::Current.reset

    third = render_listing(listing)
    expect(third.fetch('category')).to include('name_en' => 'Voitures')
    expect(third.fetch('taxonomy_version')).to eq(version + 1)
  end

  it 'freezes the snapshot so callers cannot mutate the cached taxonomy' do
    snapshot = described_class.snapshot

    expect(snapshot).to be_frozen
    expect(snapshot.version).to eq(version)
    expect(snapshot.category('cars')).to be_frozen
    expect(snapshot.category('cars')[:path]).to be_frozen
    expect(snapshot.category('cars')[:path].first).to be_frozen
  end

  it 'falls back to souq_settings.taxonomy_version and writes the key when Redis is empty' do
    clear_taxonomy_version
    described_class.reset!
    Fabricate(:souq_setting, taxonomy_version: 9)

    expect(described_class.version).to eq(9)
    expect(read_taxonomy_version).to eq('9')
  end
end
