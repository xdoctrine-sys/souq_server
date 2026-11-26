# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'

# M-05.4 section 3 — reliability of `Souq::Listings::Update` and
# `Souq::Listings::ChangeState`. Each example is the red/green witness of one
# confirmed defect:
#
#   A. the object returned by a text-changing update was stale in memory, so the
#      HTTP response could carry the previous title/price (the `souq_listing`
#      association is cached on the status by the read policy before the write);
#   B. `media_ids` was accepted by the controller but dropped by the service, so
#      a media selection (or a medias change to an unauthorized attachment) was a
#      silent no-op instead of being applied or refused;
#   C. a price/title/state refresh broadcast a `status.update` without consuming
#      the `statuses` rate-limit quota that a Mastodon edit consumes.
RSpec.describe 'SOUQ listing update reliability', type: :request do
  include_context 'with API authentication', oauth_scopes: 'read read:statuses write write:statuses'

  let(:version) { 11 }
  let(:owner) { user.account }
  let(:limit) { RateLimiter::FAMILIES[:statuses][:limit] }

  let!(:cars) { Fabricate(:souq_category, code: 'cars', hashtag: 'cars', name_en: 'Cars', name_ar: 'سيارات') }

  before do
    write_taxonomy_version(version)
    Souq::TaxonomyCache.reset!
  end

  def owned_listing(**overrides)
    status = Fabricate(:status, account: owner, visibility: :public)
    Fabricate(:souq_listing, status:, account: owner, category: cars, category_code: 'cars', **overrides)
  end

  # The real Mastodon client edits a status with a JSON body (`api().request`
  # with `data:` in app/javascript/mastodon/actions/compose.js). The default
  # request-spec encoding is `application/x-www-form-urlencoded`, which cannot
  # represent an empty array: Rack turns `media_ids: []` into `[""]`, and the
  # empty string then reads as media id 0. The few examples whose intent is an
  # *empty* selection therefore opt back into the JSON body the client sends.
  def update_listing(listing, status: nil, json: false, **listing_params)
    params = { listing: { title: 'Refreshed title', price_mode: 'fixed', price: '149000.00' }.merge(listing_params) }
    params[:status] = status if status

    if json
      put "/api/v1/souq/listings/#{listing.id}", params: params, as: :json, headers: headers
    else
      put "/api/v1/souq/listings/#{listing.id}", params: params, headers: headers
    end
  end

  def media_ids(json)
    json.fetch('media_attachments').map { |attachment| attachment.fetch('id') }
  end

  describe 'A. object returned after a change' do
    it 'returns the values actually persisted after a combined text and listing change' do
      listing = owned_listing

      update_listing(listing,
                     status: { status: 'A fresh listing text' },
                     title: 'Fresh title', price_mode: 'negotiable', price: '149000.00')

      expect(response).to have_http_status(200)
      expect(listing.reload).to have_attributes(title: 'Fresh title', price_mode: 'negotiable', price_minor: 14_900_000)
      expect(response.parsed_body.fetch('souq_listing')).to include(
        'title' => listing.title,
        'state' => 'active'
      )
      expect(response.parsed_body.fetch('souq_listing').fetch('price')).to include('minor' => 14_900_000)
    end

    it 'returns the values actually persisted after a listing-only change' do
      listing = owned_listing

      update_listing(listing, title: 'Listing only title', price_mode: 'fixed', price: '149000.00')

      expect(response).to have_http_status(200)
      expect(listing.reload.title).to eq('Listing only title')
      expect(response.parsed_body.fetch('souq_listing').fetch('title')).to eq('Listing only title')
    end

    it 'returns the committed state after a state change' do
      listing = owned_listing

      post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'sold' }, headers: headers

      expect(response).to have_http_status(200)
      expect(listing.reload.state).to eq('sold')
      expect(response.parsed_body.fetch('souq_listing').fetch('state')).to eq('sold')
    end
  end

  describe 'B. media changes' do
    it 'attaches a media attachment carried by media_ids' do
      listing = owned_listing
      media = Fabricate(:media_attachment, account: owner)

      update_listing(listing, status: { media_ids: [media.id.to_s] })

      expect(response).to have_http_status(200)
      expect(listing.status.reload.ordered_media_attachments).to eq([media])
      expect(media_ids(response.parsed_body)).to eq([media.id.to_s])
    end

    it 'replaces the current media selection' do
      listing = owned_listing
      existing = Fabricate(:media_attachment, account: owner)
      replacement = Fabricate(:media_attachment, account: owner)
      listing.status.media_attachments << existing

      update_listing(listing, status: { media_ids: [replacement.id.to_s] })

      expect(response).to have_http_status(200)
      expect(listing.status.reload.ordered_media_attachments).to eq([replacement])
      expect(media_ids(response.parsed_body)).to eq([replacement.id.to_s])
    end

    it 'removes the media selection when media_ids is empty' do
      listing = owned_listing
      existing = Fabricate(:media_attachment, account: owner)
      listing.status.media_attachments << existing

      update_listing(listing, status: { media_ids: [] }, json: true)

      expect(response).to have_http_status(200), response.body
      expect(listing.status.reload.ordered_media_attachments).to be_empty
      expect(media_ids(response.parsed_body)).to be_empty
    end

    it 'refuses a media attachment the author does not own instead of succeeding silently' do
      listing = owned_listing
      foreign_media = Fabricate(:media_attachment, account: Fabricate(:account))

      update_listing(listing, status: { media_ids: [foreign_media.id.to_s] })

      expect(response).to have_http_status(422)
      expect(listing.reload.title).to eq('Test listing')
      expect(listing.status.reload.ordered_media_attachments).to be_empty
    end

    it 'applies a media description carried by media_attributes' do
      listing = owned_listing
      media = Fabricate(:media_attachment, account: owner, description: 'Old description')
      listing.status.media_attachments << media

      update_listing(listing, status: { media_ids: [media.id.to_s], media_attributes: [{ id: media.id.to_s, description: 'New description' }] })

      expect(response).to have_http_status(200)
      expect(media.reload.description).to eq('New description')
    end
  end

  describe 'C. rate limit' do
    # The response's own `X-RateLimit-*` headers cannot witness this defect:
    # Rack::Attack's per-token API throttle has a limit of 300/5min, so it
    # yields exactly the same `X-RateLimit-Remaining` as the `statuses` family
    # (300/3h) and the header reads `299` whether or not the `statuses` quota
    # was consumed. The quota is therefore read straight from the shared
    # RateLimiter the application uses.
    def statuses_remaining
      RateLimiter.new(owner, family: :statuses).to_headers['X-RateLimit-Remaining'].to_i
    end

    def exhaust_statuses_quota!(account)
      limiter = RateLimiter.new(account, family: :statuses)
      limit.times { limiter.record! }
    end

    it 'consumes the statuses quota on a listing-only refresh' do
      listing = owned_listing

      expect { update_listing(listing) }
        .to change { statuses_remaining }.from(limit).to(limit - 1)

      expect(response).to have_http_status(200)
    end

    it 'consumes the statuses quota on a state change' do
      listing = owned_listing

      expect { post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'sold' }, headers: headers }
        .to change { statuses_remaining }.from(limit).to(limit - 1)

      expect(response).to have_http_status(200)
    end

    it 'reports the statuses quota in the headers of a state change' do
      listing = owned_listing
      5.times { RateLimiter.new(owner, family: :statuses).record! }

      post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'sold' }, headers: headers

      expect(response).to have_http_status(200)
      expect(response.headers['X-RateLimit-Limit']).to eq(limit.to_s)
      expect(response.headers['X-RateLimit-Remaining']).to eq((limit - 6).to_s)
    end

    it 'does not count twice when the same request also changes the text' do
      listing = owned_listing

      expect { update_listing(listing, status: { status: 'A text change counted once' }) }
        .to change { statuses_remaining }.from(limit).to(limit - 1)

      expect(response).to have_http_status(200)
    end

    it 'answers 429 once the quota is exhausted, without writing the listing' do
      listing = owned_listing
      exhaust_statuses_quota!(owner)

      update_listing(listing)

      expect(response).to have_http_status(429)
      expect(listing.reload.title).to eq('Test listing')
    end
  end
end
