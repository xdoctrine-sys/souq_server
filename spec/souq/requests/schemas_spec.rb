# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'
require_relative '../support/attributes'
require_relative '../support/schema_reference'

# GET /api/v1/souq/categories/:code/schema (design section 6.1, prompt
# requirement 4). The endpoint is public, reads the in-memory taxonomy snapshot
# and answers its number of SQL queries does not depend on the size of the
# schema it renders.
RSpec.describe 'SOUQ category schema API', type: :request do
  include SouqSchemaReference

  let(:version) { 11 }

  before do
    install_reference_schema
    write_taxonomy_version(version)
    Souq::TaxonomyCache.reset!
  end

  def get_schema(code, request_headers = {})
    get "/api/v1/souq/categories/#{code}/schema", headers: request_headers
  end

  def count_queries(&block)
    statements = []
    counter = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)
    statements
  end

  def install_invalid_category
    root = reference_category('invalid_root', 'Root', 'جذر')
    child = reference_category('invalid_child', 'Child', 'ابن', parent: root)
    definition = reference_definition('invalid_attr', 0, 'single_option')
    reference_rule(root, definition, mode: :enable)
    # The very same attribute enabled twice cannot resolve.
    reference_rule(child, definition, mode: :enable)
    Souq::TaxonomyCache.reset!
  end

  it 'is public and needs no token' do
    get_schema('cars')

    expect(response).to have_http_status(200)
  end

  it 'returns the labels, the version and the ordered attribute codes of the category' do
    get_schema('cars')

    expect(response).to have_http_status(200)
    expect(response.content_type).to start_with('application/json')
    body = response.parsed_body
    expect(body.fetch('category')).to eq('code' => 'cars', 'name_en' => 'Cars', 'name_ar' => 'سيارات', 'path' => %w(vehicles cars))
    expect(body.fetch('taxonomy_version')).to eq(version)
    expect(body.fetch('attributes').pluck('code')).to eq(%w(transaction_type year brand model mileage_km vehicle_condition deposit min_rental_days))
  end

  it 'exposes the condition and the options of an attribute as data' do
    get_schema('cars')

    attributes = response.parsed_body.fetch('attributes')
    deposit = attributes.find { |entry| entry['code'] == 'deposit' }
    expect(deposit.fetch('condition')).to eq('attribute' => 'transaction_type', 'in' => ['rent'])
    model = attributes.find { |entry| entry['code'] == 'model' }
    expect(model.fetch('depends_on')).to eq('brand')
    expect(model.fetch('options').pluck('code')).to eq(%w(corolla patrol))
  end

  it 'answers 404 for an unknown category' do
    get_schema('nowhere')

    expect(response).to have_http_status(404)
  end

  it 'answers 404 for an inactive category' do
    Fabricate(:souq_category, code: 'hidden', active: false)
    Souq::TaxonomyCache.reset!

    get_schema('hidden')

    expect(response).to have_http_status(404)
  end

  it 'answers 503 when the effective schema of the category is invalid' do
    install_invalid_category

    get_schema('invalid_child')

    expect(response).to have_http_status(503)
  end

  it 'answers 304 when the client sends the ETag back' do
    get_schema('cars')
    etag = response.headers.fetch('ETag')

    get_schema('cars', 'If-None-Match' => etag)

    expect(response).to have_http_status(304)
  end

  it 'changes the ETag when the taxonomy version changes' do
    get_schema('cars')
    etag = response.headers.fetch('ETag')
    write_taxonomy_version(version + 1)
    Souq::TaxonomyCache.reset!

    get_schema('cars', 'If-None-Match' => etag)

    expect(response).to have_http_status(200)
    expect(response.headers.fetch('ETag')).to_not eq(etag)
  end

  it 'issues the same constant number of queries whatever the schema size' do
    warm_taxonomy_cache
    # One throwaway request pays the one-time per-process warm-up of the ambient
    # Mastodon request path (schema cache and IP block cache), so what is
    # measured below is only what the schema rendering itself costs.
    get_schema('cars')

    fat = count_queries { get_schema('cars') }
    thin = count_queries { get_schema('vehicles') }

    expect(fat.size).to eq(thin.size)
    expect(fat.grep(/souq_attribute_definitions|souq_attribute_options|souq_category_attributes/)).to be_empty
    expect(thin.grep(/souq_attribute_definitions|souq_attribute_options|souq_category_attributes/)).to be_empty
  end
end
