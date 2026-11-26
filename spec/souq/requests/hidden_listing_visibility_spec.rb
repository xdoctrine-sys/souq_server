# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'

# M-05.4 — a listing whose `state` is `hidden` (the moderation state, design
# section 3.6 and 5.3) must not remain reachable through any *local* read
# surface. The client only hides the SOUQ card, so before the correction the
# post text and its media stayed publicly readable through the Mastodon status
# endpoint and the timelines (audit M-05.4, `bd2df9caae`).
#
# The surfaces covered here are the ones a reader can hit directly:
#   * GET /api/v1/souq/listings/:id      (SOUQ read API)
#   * GET /api/v1/statuses/:id           (Mastodon status API)
#   * GET /api/v1/timelines/public       (public timeline)
#   * GET /api/v1/accounts/:id/statuses  (profile)
#   * GET /api/v1/timelines/home         (redis-backed home feed / subscriptions)
#
# The owner keeps the access the product grants them: the platform lock on
# `hidden` answers 422 (not 404), so the owner must still resolve their own
# status through the direct endpoints (Listings::ChangeState).
#
# Out of scope, and deliberately not asserted here: media already served under a
# known URL, and copies already federated to remote servers. Mastodon does not
# revoke either, and this lot does not pretend to.
RSpec.describe 'SOUQ hidden listing visibility', type: :request do
  include_context 'with API authentication', oauth_scopes: 'read read:statuses write write:statuses'

  let(:version) { 11 }
  let(:owner) { user.account }
  let(:seller) { Fabricate(:account) }

  let!(:vehicles) { Fabricate(:souq_category, code: 'vehicles', name_en: 'Vehicles', name_ar: 'مركبات') }
  let!(:cars) { Fabricate(:souq_category, code: 'cars', hashtag: 'cars', name_en: 'Cars', name_ar: 'سيارات', parent: vehicles) }

  before do
    write_taxonomy_version(version)
    Souq::TaxonomyCache.reset!
  end

  # Builds a listing (and its public status) for an arbitrary account without
  # going through the API, so visibility can be observed from another identity.
  def listing_for(account, state: 'active')
    status = Fabricate(:status, account:, visibility: :public)
    Fabricate(:souq_listing, status:, account:, category: cars, category_code: 'cars', state:)
  end

  def status_ids(json)
    json.map { |status| status.fetch('id') }
  end

  describe 'GET /api/v1/statuses/:id' do
    it 'answers 404 and leaks no text or listing to an anonymous reader' do
      listing = listing_for(seller, state: 'hidden')

      get "/api/v1/statuses/#{listing.status_id}"

      expect(response).to have_http_status(404)
      expect(response.parsed_body).to_not have_key('text')
      expect(response.parsed_body).to_not have_key('souq_listing')
      expect(response.parsed_body).to_not have_key('media_attachments')
    end

    it 'answers 404 to an authenticated reader who is not the owner' do
      listing = listing_for(seller, state: 'hidden')

      get "/api/v1/statuses/#{listing.status_id}", headers: headers

      expect(response).to have_http_status(404)
      expect(response.parsed_body).to_not have_key('souq_listing')
    end

    it 'still serves a visible listing' do
      listing = listing_for(seller, state: 'active')

      get "/api/v1/statuses/#{listing.status_id}"

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch('souq_listing').fetch('state')).to eq('active')
    end

    it 'leaves a plain Mastodon status untouched' do
      status = Fabricate(:status, account: seller, visibility: :public)

      get "/api/v1/statuses/#{status.id}"

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch('id')).to eq(status.id.to_s)
    end

    it 'keeps the owner able to resolve their own hidden status' do
      listing = listing_for(owner, state: 'hidden')

      get "/api/v1/statuses/#{listing.status_id}", headers: headers

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch('souq_listing').fetch('state')).to eq('hidden')
    end
  end

  describe 'GET /api/v1/souq/listings/:id' do
    it 'answers 404 for a hidden listing' do
      listing = listing_for(seller, state: 'hidden')

      get "/api/v1/souq/listings/#{listing.id}", headers: headers

      expect(response).to have_http_status(404)
      expect(response.parsed_body).to_not have_key('souq_listing')
    end

    it 'answers 404 for a hidden listing to an anonymous reader' do
      listing = listing_for(seller, state: 'hidden')

      get "/api/v1/souq/listings/#{listing.id}"

      expect(response).to have_http_status(404)
    end

    it 'keeps the owner able to read their own hidden listing' do
      listing = listing_for(owner, state: 'hidden')

      get "/api/v1/souq/listings/#{listing.id}", headers: headers

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch('souq_listing').fetch('state')).to eq('hidden')
    end
  end

  describe 'GET /api/v1/timelines/public' do
    it 'removes a hidden listing while keeping a visible one' do
      visible = listing_for(seller, state: 'active')
      hidden = listing_for(seller, state: 'hidden')

      get '/api/v1/timelines/public', params: { limit: 20 }, headers: headers

      expect(response).to have_http_status(200)
      ids = status_ids(response.parsed_body)
      expect(ids).to include(visible.status_id.to_s)
      expect(ids).to_not include(hidden.status_id.to_s)
    end
  end

  describe 'GET /api/v1/accounts/:id/statuses' do
    it 'removes a hidden listing from the seller profile' do
      visible = listing_for(seller, state: 'active')
      hidden = listing_for(seller, state: 'hidden')

      get "/api/v1/accounts/#{seller.id}/statuses", headers: headers

      expect(response).to have_http_status(200)
      ids = status_ids(response.parsed_body)
      expect(ids).to include(visible.status_id.to_s)
      expect(ids).to_not include(hidden.status_id.to_s)
    end

    it 'keeps a hidden listing visible to its author on their own profile' do
      hidden = listing_for(owner, state: 'hidden')

      get "/api/v1/accounts/#{owner.id}/statuses", headers: headers

      expect(response).to have_http_status(200)
      expect(status_ids(response.parsed_body)).to include(hidden.status_id.to_s)
    end
  end

  describe 'GET /api/v1/timelines/home' do
    it 'removes a hidden listing from a follower home feed' do
      poster = Fabricate(:account)
      visible = listing_for(poster, state: 'active')
      hidden = listing_for(poster, state: 'hidden')

      owner.follow!(poster)
      FeedManager.instance.push_to_home(owner, visible.status)
      FeedManager.instance.push_to_home(owner, hidden.status)

      get '/api/v1/timelines/home', headers: headers

      expect(response).to have_http_status(200)
      ids = status_ids(response.parsed_body)
      expect(ids).to include(visible.status_id.to_s)
      expect(ids).to_not include(hidden.status_id.to_s)
    end
  end

  describe 'owner state transitions' do
    it 'keeps the platform lock on a hidden listing (422, not a silent success)' do
      listing = listing_for(owner, state: 'hidden')

      post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'active' }, headers: headers

      expect(response).to have_http_status(422)
      expect(response.parsed_body.fetch('details').fetch('listing.state')).to include('cannot be changed by the owner')
      expect(listing.reload.state).to eq('hidden')
    end

    it 'locks a hidden listing against the owner update route as well' do
      listing = listing_for(owner, state: 'hidden')

      put "/api/v1/souq/listings/#{listing.id}", params: { listing: { title: 'Reactivated' } }, headers: headers

      expect(response).to have_http_status(422)
      expect(listing.reload.state).to eq('hidden')
    end
  end
end
