# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'

RSpec.describe 'SOUQ listings API', type: :request do
  include_context 'with API authentication', oauth_scopes: 'read read:statuses write write:statuses'

  let(:version) { 11 }
  let(:author) { Fabricate(:user) }
  let!(:vehicles) { Fabricate(:souq_category, code: 'vehicles', name_en: 'Vehicles', name_ar: 'مركبات') }
  let!(:cars) { Fabricate(:souq_category, code: 'cars', hashtag: 'cars', name_en: 'Cars', name_ar: 'سيارات', parent: vehicles) }

  let(:status_payload) do
    { status: 'Toyota Land Cruiser 2019 for sale', visibility: 'public' }
  end

  let(:listing_payload) do
    { category: 'cars', title: 'Toyota Land Cruiser 2019', price_mode: 'fixed', price: '145000.00' }
  end

  before do
    write_taxonomy_version(version)
    Souq::TaxonomyCache.reset!
  end

  def create_listing(listing: listing_payload, status: status_payload, request_headers: headers)
    post '/api/v1/souq/listings', params: { status:, listing: }, headers: request_headers
  end

  # Builds a listing for an arbitrary account without going through the API, so
  # that authorization and visibility can be tested from another identity.
  def fabricate_listing(account:, **overrides)
    status = Fabricate(:status, account:, visibility: :public)
    Fabricate(:souq_listing, status:, account:, category: cars, category_code: 'cars', **overrides)
  end

  # A rejected request never reaches PostStatusService: no status, no listing and
  # no distribution job may exist.
  def expect_rejected(field, message, listing: listing_payload, status: status_payload)
    create_listing(listing:, status:)

    expect(response).to have_http_status(422)
    expect(response.parsed_body.fetch('details').fetch(field)).to include(a_string_including(message))
    expect(Status.count).to eq(0)
    expect(Souq::Listing.count).to eq(0)
    expect(DistributionWorker.jobs).to be_empty
  end

  # Runs the distribution jobs the request enqueued, so that the fan-out (and
  # therefore the notifications it may or may not send) actually happens.
  def run_enqueued_distribution
    DistributionWorker.jobs.each { |job| DistributionWorker.new.perform(*job['args']) }
  end

  def distribution_job_arguments
    DistributionWorker.jobs.map { |job| job['args'] }
  end

  def created_listing_json(listing)
    {
      'id' => listing.id.to_s,
      'title' => 'Toyota Land Cruiser 2019',
      'category' => { 'code' => 'cars', 'name_en' => 'Cars', 'name_ar' => 'سيارات', 'path' => %w(vehicles cars) },
      'price' => { 'mode' => 'fixed', 'amount' => '145000.00', 'minor' => 14_500_000, 'currency' => 'QAR', 'period' => 'once' },
      'location' => nil,
      'attributes' => [],
      'state' => 'active',
      'taxonomy_version' => version,
    }
  end

  describe 'POST /api/v1/souq/listings' do
    it 'creates the status and its listing in one request' do
      expect { create_listing }.to change(Status, :count).by(1).and change(Souq::Listing, :count).by(1)

      expect(response).to have_http_status(200)
      expect(response.content_type).to start_with('application/json')
      expect(response.parsed_body.fetch('souq_listing')).to eq(created_listing_json(Souq::Listing.sole))
    end

    it 'stores the account, the category, the price and the published timestamp' do
      create_listing

      listing = Souq::Listing.sole
      expect(listing).to have_attributes(
        account_id: user.account.id,
        category_code: 'cars',
        title: 'Toyota Land Cruiser 2019',
        price_mode: 'fixed',
        price_minor: 14_500_000,
        currency: 'QAR',
        price_period: 'once',
        state: 'active',
        local: true,
        attribute_values: {}
      )
      expect(listing.published_at).to eq(listing.status.created_at)
    end

    it 'counts against the statuses rate limit' do
      create_listing

      expect(response.headers['X-RateLimit-Limit']).to eq(RateLimiter::FAMILIES[:statuses][:limit].to_s)
      expect(response.headers['X-RateLimit-Remaining']).to eq((RateLimiter::FAMILIES[:statuses][:limit] - 1).to_s)
    end

    it 'appends the category hashtag once when it is missing' do
      create_listing(status: status_payload.merge(status: 'Toyota for sale'))

      expect(Status.sole.text).to eq('Toyota for sale #cars')
      expect(Status.sole.tags.map(&:name)).to contain_exactly('cars')
    end

    it 'does not append a hashtag already present in another case' do
      create_listing(status: status_payload.merge(status: 'Selling my #Cars today'))

      expect(Status.sole.text).to eq('Selling my #Cars today')
      expect(Status.sole.text.scan(/#cars/i).length).to eq(1)
      expect(Status.sole.tags.map(&:name)).to contain_exactly('cars')
    end

    it 'accepts a known active location' do
      location = Fabricate(:souq_location, code: 'doha', name_en: 'Doha', name_ar: 'الدوحة')

      create_listing(listing: listing_payload.merge(location: 'doha'))

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch('souq_listing').fetch('location')).to eq('code' => 'doha', 'name_en' => 'Doha', 'name_ar' => 'الدوحة')
      expect(Souq::Listing.sole.location_id).to eq(location.id)
    end

    it 'rejects a scheduled_at' do
      expect_rejected('status.scheduled_at', 'is not supported for listings', status: status_payload.merge(scheduled_at: 1.hour.from_now.iso8601))
    end

    it 'rejects a visibility that is not public or unlisted' do
      %w(private direct).each do |visibility|
        expect_rejected('status.visibility', 'must be public or unlisted', status: status_payload.merge(visibility:))
      end
    end

    it 'rejects a text longer than the status limit' do
      expect_rejected('status.status', 'is too long', status: status_payload.merge(status: 'a' * 500))
    end

    it 'rejects a missing category' do
      expect_rejected('listing.category', 'is required', listing: listing_payload.except(:category))
    end

    it 'rejects an unknown, inactive or non-listable category' do
      expect_rejected('listing.category', 'does not exist', listing: listing_payload.merge(category: 'unknown'))

      Fabricate(:souq_category, code: 'inactive', active: false)
      expect_rejected('listing.category', 'is not active', listing: listing_payload.merge(category: 'inactive'))

      Fabricate(:souq_category, code: 'archived', listable: false)
      expect_rejected('listing.category', 'is not listable', listing: listing_payload.merge(category: 'archived'))
    end

    it 'rejects a title that is missing, too long or unsafe' do
      expect_rejected('listing.title', 'is required', listing: listing_payload.merge(title: '   '))
      expect_rejected('listing.title', 'is too long (maximum is 140 characters)', listing: listing_payload.merge(title: 'x' * 141))
      expect_rejected('listing.title', 'must not contain control characters', listing: listing_payload.merge(title: "bad\u0000title"))
    end

    it 'rejects an unknown price mode' do
      expect_rejected('listing.price_mode', 'is required', listing: listing_payload.except(:price_mode))
      expect_rejected('listing.price_mode', 'must be one of', listing: listing_payload.merge(price_mode: 'auction'))
    end

    it 'rejects an incoherent price' do
      expect_rejected('listing.price', 'is required', listing: listing_payload.except(:price))
      expect_rejected('listing.price', 'Too many decimal places', listing: listing_payload.merge(price: '1.234'))
      expect_rejected('listing.price', 'must be absent unless the price mode is fixed or negotiable', listing: listing_payload.merge(price_mode: 'free'))
    end

    it 'rejects an unsupported currency' do
      expect_rejected('listing.currency', 'is not an allowed currency', listing: listing_payload.merge(currency: 'USD'))
    end

    it 'rejects an unknown location' do
      expect_rejected('listing.location', 'does not exist', listing: listing_payload.merge(location: 'nowhere'))
    end

    it 'rejects attributes until the validator is available' do
      expect_rejected('listing.attributes', 'must be empty until the attribute validator is available', listing: listing_payload.merge(attributes: { brand: 'Toyota' }))
    end

    it 'leaves no trace after a rejection' do
      expect { create_listing(listing: listing_payload.merge(category: 'unknown')) }.to not_change(Status, :count).and not_change(Souq::Listing, :count)

      expect(Souq::Current.listing_draft).to be_nil
    end
  end

  describe 'POST /api/v1/statuses' do
    it 'creates no listing when a status is posted on the Mastodon route' do
      expect do
        post '/api/v1/statuses', params: { status: 'Plain upstream status', visibility: 'public' }, headers: headers
      end.to change(Status, :count).by(1)

      expect(response).to have_http_status(200)
      expect(response.parsed_body).to_not have_key('souq_listing')
      expect(Souq::Listing.count).to eq(0)
      expect(Souq::Current.listing_draft).to be_nil
    end
  end

  describe 'GET /api/v1/souq/listings/:id' do
    it 'returns the status carrying the listing' do
      create_listing
      listing = Souq::Listing.sole

      get "/api/v1/souq/listings/#{listing.id}", headers: headers

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch('id')).to eq(listing.status_id.to_s)
      expect(response.parsed_body.fetch('souq_listing')).to eq(created_listing_json(listing))
    end

    it 'answers the same 404 for an unknown listing' do
      get "/api/v1/souq/listings/#{Souq::Listing.maximum(:id).to_i + 1_000}", headers: headers

      expect(response).to have_http_status(404)
      expect(response.content_type).to start_with('application/json')
    end

    it 'never resolves a status id as a listing id' do
      create_listing
      status_id = Souq::Listing.sole.status_id
      plain = Fabricate(:status, id: status_id + 1_000_000, account: author.account)

      expect(Souq::Listing.exists?(id: plain.id)).to be(false)

      get "/api/v1/statuses/#{plain.id}", headers: headers
      expect(response).to have_http_status(200)

      get "/api/v1/souq/listings/#{plain.id}", headers: headers
      expect(response).to have_http_status(404)
    end

    it 'answers 404 when the author hides the requester' do
      listing = fabricate_listing(account: author.account)
      author.account.block!(user.account)

      get "/api/v1/souq/listings/#{listing.id}", headers: headers

      expect(response).to have_http_status(404)
    end

    it 'answers 404 when the listing status is not visible' do
      listing = fabricate_listing(account: author.account)
      listing.status.update!(visibility: :private)

      get "/api/v1/souq/listings/#{listing.id}", headers: headers

      expect(response).to have_http_status(404)
    end
  end

  describe 'PUT /api/v1/souq/listings/:id' do
    it 'answers 403 for another visible listing' do
      listing = fabricate_listing(account: author.account)

      put "/api/v1/souq/listings/#{listing.id}", params: { listing: { title: 'Hacked' } }, headers: headers

      expect(response).to have_http_status(403)
    end

    it 'answers 404 when the requester cannot see the listing' do
      listing = fabricate_listing(account: author.account)
      author.account.block!(user.account)

      put "/api/v1/souq/listings/#{listing.id}", params: { listing: { title: 'Hacked' } }, headers: headers

      expect(response).to have_http_status(404)
    end

    it 'answers 404 for an unknown listing' do
      put "/api/v1/souq/listings/#{Souq::Listing.maximum(:id).to_i + 1_000}", params: { listing: { title: 'Updated' } }, headers: headers

      expect(response).to have_http_status(404)
    end

    it 'answers 401 without a token' do
      listing = fabricate_listing(account: user.account)

      put "/api/v1/souq/listings/#{listing.id}", params: { listing: { title: 'Updated' } }

      expect(response).to have_http_status(401)
    end

    context 'with a read-only scope' do
      subject(:listing_request) { put "/api/v1/souq/listings/#{listing.id}", params: { listing: { title: 'Updated' } }, headers: headers }

      let(:listing) { fabricate_listing(account: user.account) }

      it_behaves_like 'forbidden for wrong scope', 'read read:statuses'
    end

    it 'updates the listing, publishes status.update and never edits the status', :inline_jobs do
      listing = fabricate_listing(account: user.account)
      status = listing.status
      allow(redis).to receive(:publish).and_call_original

      put "/api/v1/souq/listings/#{listing.id}",
          params: { listing: { title: 'Updated title', price_mode: 'negotiable', price: '149000.00' } },
          headers: headers

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch('souq_listing').fetch('title')).to eq('Updated title')
      expect(listing.reload).to have_attributes(title: 'Updated title', price_mode: 'negotiable', price_minor: 14_900_000)
      expect(status.reload.edited_at).to be_nil
      expect(StatusEdit.where(status:).count).to eq(0)
      expect(redis).to have_received(:publish).with('timeline:public', anything) do |_channel, message|
        expect(JSON.parse(message).fetch('event')).to eq('status.update')
      end
    end

    it 'edits the status when the request carries new text and does not distribute twice', :inline_jobs do
      listing = fabricate_listing(account: user.account)
      status = listing.status
      original_text = status.text
      allow(redis).to receive(:publish).and_call_original
      allow(DistributionWorker).to receive(:perform_async).and_call_original

      put "/api/v1/souq/listings/#{listing.id}",
          params: { status: { status: 'Updated listing text' }, listing: { title: 'Updated title', price_mode: 'fixed', price: '145000.00' } },
          headers: headers

      expect(response).to have_http_status(200)
      expect(status.reload.edited_at).to be_present
      expect(status.edits.ordered.pluck(:text)).to eq([original_text, 'Updated listing text'])
      expect(DistributionWorker).to have_received(:perform_async).once.with(status.id, { 'update' => true })
      expect(redis).to have_received(:publish).with('timeline:public', anything) do |_channel, message|
        expect(JSON.parse(message).fetch('event')).to eq('status.update')
      end
    end

    it 'notifies the accounts that shared the status when the text changes' do
      listing = fabricate_listing(account: user.account)
      reblogger = Fabricate(:account)
      Fabricate(:status, account: reblogger, reblog: listing.status)

      put "/api/v1/souq/listings/#{listing.id}",
          params: { status: { status: 'A brand new listing text' }, listing: { title: 'Updated title', price_mode: 'fixed', price: '145000.00' } },
          headers: headers

      expect(response).to have_http_status(200)
      expect(distribution_job_arguments).to eq([[listing.status_id, { 'update' => true }]])
      expect { run_enqueued_distribution }.to enqueue_sidekiq_job(LocalNotificationWorker).with(reblogger.id, listing.status_id, 'Status', 'update')
    end

    it 'refuses to change the category' do
      listing = fabricate_listing(account: user.account)

      put "/api/v1/souq/listings/#{listing.id}", params: { listing: listing_payload.merge(category: vehicles.code) }, headers: headers

      expect(response).to have_http_status(422)
      expect(response.parsed_body.fetch('details').fetch('listing.category')).to include('cannot be changed yet')
      expect(listing.reload.category_code).to eq('cars')
    end
  end

  describe 'POST /api/v1/souq/listings/:id/state' do
    it 'answers 403 for another visible listing' do
      listing = fabricate_listing(account: author.account)

      post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'sold' }, headers: headers

      expect(response).to have_http_status(403)
    end

    it 'answers 404 when the requester cannot see the listing' do
      listing = fabricate_listing(account: author.account)
      author.account.block!(user.account)

      post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'sold' }, headers: headers

      expect(response).to have_http_status(404)
    end

    it 'answers 401 without a token' do
      listing = fabricate_listing(account: user.account)

      post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'sold' }

      expect(response).to have_http_status(401)
    end

    it 'marks a listing as sold and publishes an update', :inline_jobs do
      listing = fabricate_listing(account: user.account)
      allow(redis).to receive(:publish).and_call_original

      post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'sold' }, headers: headers

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch('souq_listing').fetch('state')).to eq('sold')
      expect(listing.reload.state).to eq('sold')
      expect(listing.sold_at).to be_present
      expect(listing.status.reload.edited_at).to be_nil
      expect(redis).to have_received(:publish).with('timeline:public', anything) do |_channel, message|
        expect(JSON.parse(message).fetch('event')).to eq('status.update')
      end
    end

    it 'refreshes the feed without notifying the accounts that shared the status' do
      listing = fabricate_listing(account: user.account)
      reblogger = Fabricate(:account)
      Fabricate(:status, account: reblogger, reblog: listing.status)

      post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'sold' }, headers: headers

      expect(response).to have_http_status(200)
      expect(distribution_job_arguments).to eq([[listing.status_id, { 'update' => true, 'skip_notifications' => true }]])
      expect { run_enqueued_distribution }.to_not enqueue_sidekiq_job(LocalNotificationWorker)
    end

    it 'clears sold_at when the listing becomes active again' do
      listing = fabricate_listing(account: user.account, state: 'sold', sold_at: 1.hour.ago)

      post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'active' }, headers: headers

      expect(response).to have_http_status(200)
      expect(listing.reload.state).to eq('active')
      expect(listing.sold_at).to be_nil
    end

    it 'refuses a state the owner may not set' do
      listing = fabricate_listing(account: user.account)

      %w(expired hidden).each do |state|
        post "/api/v1/souq/listings/#{listing.id}/state", params: { state: }, headers: headers
        expect(response).to have_http_status(422)
        expect(response.parsed_body.fetch('details').fetch('listing.state')).to include('must be one of active, reserved, sold')
      end
      expect(listing.reload.state).to eq('active')
    end

    it 'refuses to move a listing locked by the platform' do
      listing = fabricate_listing(account: user.account, state: 'hidden')

      post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'active' }, headers: headers

      expect(response).to have_http_status(422)
      expect(response.parsed_body.fetch('details').fetch('listing.state')).to include('cannot be changed by the owner')
      expect(listing.reload.state).to eq('hidden')
    end
  end
end
