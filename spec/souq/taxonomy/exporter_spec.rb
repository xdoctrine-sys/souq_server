# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'
require_relative '../support/taxonomy_document'

# T3: the exporter produces the versioned document the importer accepts. The
# output must be deterministic and lossless so an export can be re-imported as
# is, and it must never invent a label or a link.
RSpec.describe Souq::Taxonomy::Exporter do
  let!(:account) { Fabricate(:account) }

  def import(raw)
    Souq::Taxonomy::Importer.call(document: Souq::Taxonomy::Document.new(raw), account: account)
  end

  it 'exports an empty database without inventing any row' do
    document = described_class.call

    expect(document['format_version']).to eq(Souq::Taxonomy::Document::FORMAT_VERSION)
    expect(document['taxonomy_version']).to eq(Souq::TaxonomyCache::BOOTSTRAP_VERSION)
    expect(document['markets']).to eq([])
    expect(document['categories']).to eq([])
    expect(document['attributes']).to eq([])
    expect(document['locations']).to eq([])
  end

  it 'exports a deterministic document the validator accepts' do
    import(reference_document)

    first = described_class.call

    expect(first).to eq(described_class.call)
    expect(first['taxonomy_version']).to eq(read_taxonomy_version)
    expect { Souq::Taxonomy::Document.new(first) }.to_not raise_error
  end

  it 'lists categories depth first and keeps every label as stored' do
    import(reference_document)

    document = described_class.call
    codes = document['categories'].map { |category| [category['code'], category['parent_code']] }
    expect(codes).to eq(
      [
        ['vehicles', nil],
        ['vehicles__cars', 'vehicles'],
        ['vehicles__cars__spare_parts', 'vehicles__cars'],
        ['services', nil],
      ]
    )
    expect(document['markets'].map { |market| [market['code'], market['categories']] }).to eq([['motors', ['vehicles']]])
    cars = document['categories'].find { |category| category['code'] == 'vehicles__cars' }
    expect(cars['hashtag']).to eq('cars')
  end

  it 'round trips through the file format without any difference' do
    import(reference_document)

    exported = described_class.call
    report = Souq::Taxonomy::Importer.call(document: Souq::Taxonomy::Document.new(exported), account: account)

    expect(report).to_not be_changed
    expect(report.categories.unchanged).to contain_exactly('vehicles', 'vehicles__cars', 'vehicles__cars__spare_parts', 'services')
    expect(report.markets.unchanged).to eq(['motors'])
  end

  it 'accepts the Qatar document shipped in the engine' do
    document = Souq::Taxonomy::Document.load(Souq::Engine.root.join('db', 'taxonomy', 'qa.json'))

    expect(document.format_version).to eq(Souq::Taxonomy::Document::FORMAT_VERSION)
    expect(document.categories.pluck('name_en').join).to_not include('&amp;')
    expect(document.categories.filter_map { |category| category['hashtag'] }).to all(match(Tag::HASHTAG_NAME_RE))
  end
end
