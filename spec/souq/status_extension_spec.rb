# frozen_string_literal: true

require 'rails_helper'
require_relative 'support/taxonomy'
require_relative 'support/taxonomy_cache'

RSpec.describe 'SOUQ status extension', type: :request do
  include_context 'with API authentication', oauth_scopes: 'read read:statuses read:notifications'

  let(:version) { 7 }
  let(:price_mode) { 'negotiable' }
  let(:price_minor) { 14_500_000 }
  let(:currency) { 'QAR' }
  let!(:vehicles) { Fabricate(:souq_category, code: 'vehicles', name_en: 'Vehicles', name_ar: 'مركبات') }
  let!(:cars) { Fabricate(:souq_category, code: 'cars', name_en: 'Cars', name_ar: 'سيارات', parent: vehicles) }

  before do
    write_taxonomy_version(version)
    Souq::TaxonomyCache.reset!
  end

  def publish(account, text)
    PostStatusService.new.call(account, text: text, visibility: :public)
  end

  def attach_listing(status)
    Fabricate(
      :souq_listing,
      status: status,
      account: status.account,
      category: cars,
      category_code: 'cars',
      title: 'Toyota Land Cruiser 2019',
      price_mode: price_mode,
      price_minor: price_minor,
      currency: currency
    )
  end

  def expected_listing(listing)
    {
      'id' => listing.id.to_s,
      'title' => 'Toyota Land Cruiser 2019',
      'category' => { 'code' => 'cars', 'name_en' => 'Cars', 'name_ar' => 'سيارات', 'path' => %w(vehicles cars) },
      'price' => { 'mode' => price_mode, 'amount' => '145000.00', 'minor' => price_minor, 'currency' => currency, 'period' => 'once' },
      'location' => nil,
      'attributes' => [],
      'state' => 'active',
      'taxonomy_version' => version,
    }
  end

  # Counts the SQL statements issued while the block runs, grouped by table,
  # ignoring schema, transaction and savepoint bookkeeping.
  def queries_by_table(&block)
    ignored = %w(SCHEMA TRANSACTION SAVEPOINT)
    counts = Hash.new(0)
    callback = lambda do |_name, _start, _finish, _id, payload|
      next if ignored.include?(payload[:name])

      table = payload[:sql][/(?:FROM|JOIN|INTO|UPDATE)\s+"([^"]+)"/i, 1]
      counts[table] += 1 if table
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    counts
  end

  def render_statuses(statuses)
    Status.preload_cacheable_associations(statuses)
    statuses.each do |status|
      serialized_record_json(status, REST::StatusSerializer, options: { scope: nil, scope_name: :current_user })
    end
  end

  def measure_initial_snapshot_load
    Souq::Current.reset
    Souq::TaxonomyCache.reset!
    queries_by_table { Souq::TaxonomyCache.snapshot }
  end

  def measure_series(statuses)
    render_statuses(statuses) # warm-up pass, result ignored
    queries_by_table { render_statuses(statuses) }
  end

  def build_plain(count)
    Array.new(count) { publish(user.account, 'Plain') }
  end

  def build_listed(count)
    Array.new(count) do
      status = publish(user.account, 'Listed')
      attach_listing(status)
      status
    end
  end

  def expect_flat_timeline(plain_counts, listed_counts)
    expect(listed_counts.fetch('souq_listings', 0)).to be <= 1
    expect(listed_counts.fetch('souq_categories', 0)).to eq(0)
    expect(listed_counts.fetch('souq_locations', 0)).to eq(0)
    expect(listed_counts.values.sum).to be <= plain_counts.values.sum + 1
  end

  describe 'GET /api/v1/statuses/:id' do
    it 'renders the exact section 7.1 field' do
      status = publish(user.account, 'Listed status')
      listing = attach_listing(status)

      get "/api/v1/statuses/#{status.id}", headers: headers

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch('souq_listing')).to eq(expected_listing(listing))
    end

    it 'omits the key for a status without a listing' do
      status = publish(user.account, 'Plain status')

      get "/api/v1/statuses/#{status.id}", headers: headers

      expect(response.parsed_body).to_not have_key('souq_listing')
    end

    it 'adds only the souq_listing key and leaves the other fields untouched' do
      status = publish(user.account, 'Plain status')

      get "/api/v1/statuses/#{status.id}", headers: headers
      plain_body = response.parsed_body

      attach_listing(status)

      get "/api/v1/statuses/#{status.id}", headers: headers
      listed_body = response.parsed_body

      expect(plain_body).to_not have_key('souq_listing')
      expect(listed_body.except('souq_listing')).to eq(plain_body)
    end
  end

  it 'renders the field in the home timeline', :inline_jobs do
    author = Fabricate(:account)
    user.account.follow!(author)
    status = publish(author, 'Home listing')
    listing = attach_listing(status)

    get '/api/v1/timelines/home', headers: headers

    expect(response).to have_http_status(200)
    entry = response.parsed_body.find { |item| item['id'] == status.id.to_s }
    expect(entry.fetch('souq_listing')).to eq(expected_listing(listing))
  end

  it 'renders the field in the public timeline', :inline_jobs do
    status = publish(Fabricate(:account), 'Public listing')
    listing = attach_listing(status)

    get '/api/v1/timelines/public', headers: headers

    expect(response).to have_http_status(200)
    entry = response.parsed_body.find { |item| item['id'] == status.id.to_s }
    expect(entry.fetch('souq_listing')).to eq(expected_listing(listing))
  end

  it 'renders the field on the reblogged status' do
    original = publish(Fabricate(:account), 'Boosted listing')
    listing = attach_listing(original)

    boost = ReblogService.new.call(Fabricate(:account), original)

    get "/api/v1/statuses/#{boost.id}", headers: headers

    expect(response.parsed_body.fetch('reblog').fetch('souq_listing')).to eq(expected_listing(listing))
  end

  it 'renders the field in notifications', :inline_jobs do
    status = publish(user.account, 'Favourited listing')
    listing = attach_listing(status)

    FavouriteService.new.call(Fabricate(:account), status)

    get '/api/v1/notifications', headers: headers

    expect(response).to have_http_status(200)
    entry = response.parsed_body.find { |item| item['type'] == 'favourite' }
    expect(entry.fetch('status').fetch('souq_listing')).to eq(expected_listing(listing))
  end

  it 'renders the field through InlineRenderer for the streaming payload' do
    status = publish(user.account, 'Streamed listing')
    listing = attach_listing(status)

    payload = JSON.parse(InlineRenderer.render(status, nil, :status).to_json)

    expect(payload.fetch('souq_listing')).to eq(expected_listing(listing))
  end

  describe 'timeline query budget' do
    it 'counts the category and location queries on the initial snapshot load only' do
      counts = measure_initial_snapshot_load

      expect(counts.fetch('souq_categories', 0)).to be >= 1
      expect(counts.fetch('souq_locations', 0)).to be >= 1
    end

    it 'adds at most one query for 20 listings, measured plain then listed' do
      measure_initial_snapshot_load
      plain_counts = measure_series(build_plain(20))
      listed_counts = measure_series(build_listed(20))

      expect_flat_timeline(plain_counts, listed_counts)
    end

    it 'adds at most one query for 20 listings, measured listed then plain' do
      measure_initial_snapshot_load
      listed_counts = measure_series(build_listed(20))
      plain_counts = measure_series(build_plain(20))

      expect_flat_timeline(plain_counts, listed_counts)
    end

    it 'keeps a real public timeline request flat for 20 listings', :inline_jobs do
      Souq::TaxonomyCache.snapshot # warm the process tree, as the first real request would
      build_plain(20)
      plain_counts = queries_by_table { get '/api/v1/timelines/public', headers: headers }

      build_listed(20)
      listed_counts = queries_by_table { get '/api/v1/timelines/public', headers: headers }

      expect(listed_counts.fetch('souq_listings', 0)).to be <= 1
      expect(listed_counts.fetch('souq_categories', 0)).to eq(0)
      expect(listed_counts.fetch('souq_locations', 0)).to eq(0)
      expect(listed_counts.values.sum).to be <= plain_counts.values.sum + 1
    end
  end
end
