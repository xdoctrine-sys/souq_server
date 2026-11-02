# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_document'

RSpec.describe Souq::Taxonomy::Document do
  def invalid(document)
    described_class.new(document)
    raise 'the document was accepted'
  rescue Souq::Taxonomy::InvalidDocumentError => e
    e.details
  end

  it 'accepts the reference tree and exposes its codes' do
    document = described_class.new(reference_document)
    expect(document.format_version).to eq(1)
    expect(document.category_codes).to eq(%w(vehicles vehicles__cars vehicles__cars__spare_parts services))
    expect(document.market_codes).to eq(['motors'])
  end

  it 'rejects an envelope that is not a valid object, version included' do
    expect { described_class.new([]) }.to raise_error(Souq::Taxonomy::InvalidDocumentError)
    expect(invalid(reference_document(format_version: 2))).to have_key('format_version')
    expect(invalid(reference_document(taxonomy_version: 0))).to have_key('taxonomy_version')
  end

  it 'rejects unknown and missing keys instead of guessing them' do
    with_extra = taxonomy_category('vehicles').merge('unexpected' => 1)
    expect(invalid(taxonomy_document(markets: [], categories: [with_extra]))).to include('categories[0]')
    missing = taxonomy_category('vehicles').except('hashtag')
    expect(invalid(taxonomy_document(markets: [], categories: [missing]))).to include('categories[0]')
  end

  it 'rejects a malformed code and a label that needs cleaning' do
    expect(invalid(taxonomy_document(markets: [], categories: [taxonomy_category('Cars')]))).to include('categories[0].code')
    expect(invalid(taxonomy_document(markets: [], categories: [taxonomy_category('cars', name_en: 'Cars &amp; Co')]))).to include('categories[0].name_en')
    expect(invalid(taxonomy_document(markets: [], categories: [taxonomy_category('cars', name_ar: ' سيارات')]))).to include('categories[0].name_ar')
  end

  it 'rejects a hashtag Mastodon would refuse' do
    expect(invalid(taxonomy_document(markets: [], categories: [taxonomy_category('cars', hashtag: 'residential-properties')]))).to include('categories[0].hashtag')
    expect(invalid(taxonomy_document(markets: [], categories: [taxonomy_category('cars', hashtag: 'Cars')]))).to include('categories[0].hashtag')
  end

  it 'rejects unknown parents, cycles and a depth beyond three' do
    orphan = taxonomy_category('cars', parent_code: 'unknown')
    expect(invalid(taxonomy_document(markets: [], categories: [orphan]))).to include('categories[cars].parent_code')

    cycle = [taxonomy_category('cycle_a', parent_code: 'cycle_b'), taxonomy_category('cycle_b', parent_code: 'cycle_a')]
    expect(invalid(taxonomy_document(markets: [], categories: cycle)).keys).to contain_exactly('categories[cycle_a]', 'categories[cycle_b]')

    chain = (0..4).map { |index| taxonomy_category("level_#{index}", parent_code: index.zero? ? nil : "level_#{index - 1}") }
    expect(invalid(taxonomy_document(markets: [], categories: chain))).to include('categories[level_4]')
  end

  it 'rejects duplicate codes, duplicate positions and an unknown market link' do
    duplicate_code = [taxonomy_category('cars'), taxonomy_category('cars', position: 1)]
    expect(invalid(taxonomy_document(markets: [], categories: duplicate_code))).to include('categories')

    duplicate_position = [taxonomy_category('cars'), taxonomy_category('bikes')]
    expect(invalid(taxonomy_document(markets: [], categories: duplicate_position))).to include('categories')

    market = taxonomy_market('motors', categories: ['unknown'])
    expect(invalid(taxonomy_document(markets: [market], categories: [taxonomy_category('cars')]))).to include('markets[motors].categories')
  end

  it 'collects every problem in one pass instead of failing one at a time' do
    details = invalid(taxonomy_document(markets: [], categories: [taxonomy_category('Cars', name_en: '')]))
    expect(details.keys).to contain_exactly('categories[0].code', 'categories[0].name_en')
  end

  it 'refuses a section whose import belongs to another task' do
    expect { described_class.new(reference_document(attributes: [{ 'code' => 'brand' }])) }
      .to raise_error(Souq::Taxonomy::UnsupportedSectionError) { |error| expect(error.section).to eq('attributes') }
    expect { described_class.new(reference_document(locations: [{ 'code' => 'doha' }])) }
      .to raise_error(Souq::Taxonomy::UnsupportedSectionError) { |error| expect(error.task).to eq('T9') }
  end

  it 'reports unparsable JSON as a document problem' do
    Tempfile.create(['taxonomy', '.json']) do |file|
      file.write('{ not json')
      file.flush
      expect { described_class.load(file.path) }
        .to raise_error(Souq::Taxonomy::InvalidDocumentError) { |error| expect(error.details).to have_key('format') }
    end
  end
end
