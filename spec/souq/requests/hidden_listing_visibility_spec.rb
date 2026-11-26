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
# Two indirect paths reach the same content and are covered too, because they
# carry identifiers of their own and escape an id-based filter:
#   * a share (reblog) created before the masking embeds the hidden status in
#     its nested `reblog` payload, and keeps a *different* id and author, so it
#     must leave the booster profile / follower feed and serve no nested content
#     through the status endpoint;
#   * a distribution task enqueued while the listing was still visible and run
#     only after the masking must publish nothing to the public streams and
#     insert nothing into a reader feed.
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

  # A share (reblog) created while the listing was still visible keeps its own
  # id and its own author, and carries the shared status in its nested `reblog`
  # payload; an id-based filter therefore misses it. It must leave the profile
  # and the feed of the account that shared it, and the status endpoint must
  # serve neither the share nor the nested content. Ordinary shares are kept.
  describe 'a share created before the listing was hidden' do
    let(:booster) { Fabricate(:account) }

    def share(status)
      ReblogService.new.call(booster, status)
    end

    it 'answers 404 and serves no nested content to an anonymous reader' do
      listing = listing_for(seller, state: 'active')
      boost = share(listing.status)
      listing.update!(state: 'hidden')

      get "/api/v1/statuses/#{boost.id}"

      expect(response).to have_http_status(404)
      expect(response.parsed_body).to_not have_key('reblog')
      expect(response.parsed_body).to_not have_key('text')
    end

    it 'answers 404 to an authenticated reader who is not the owner' do
      listing = listing_for(seller, state: 'active')
      boost = share(listing.status)
      listing.update!(state: 'hidden')

      get "/api/v1/statuses/#{boost.id}", headers: headers

      expect(response).to have_http_status(404)
      expect(response.parsed_body).to_not have_key('reblog')
    end

    it 'removes the share from the booster profile and keeps an ordinary share' do
      listing = listing_for(seller, state: 'active')
      hidden_boost = share(listing.status)
      listing.update!(state: 'hidden')

      plain = Fabricate(:status, account: seller, visibility: :public)
      plain_boost = share(plain)

      get "/api/v1/accounts/#{booster.id}/statuses", headers: headers

      expect(response).to have_http_status(200)
      ids = status_ids(response.parsed_body)
      expect(ids).to include(plain_boost.id.to_s)
      expect(ids).to_not include(hidden_boost.id.to_s)
      nested = response.parsed_body.filter_map { |status| status['reblog'] }.pluck('id')
      expect(nested).to_not include(listing.status_id.to_s)
    end

    it 'removes the share from the booster own profile when the booster is the reader' do
      listing = listing_for(seller, state: 'active')
      boost = ReblogService.new.call(owner, listing.status)
      listing.update!(state: 'hidden')

      plain = Fabricate(:status, account: seller, visibility: :public)
      plain_boost = ReblogService.new.call(owner, plain)

      get "/api/v1/accounts/#{owner.id}/statuses", headers: headers

      expect(response).to have_http_status(200)
      ids = status_ids(response.parsed_body)
      expect(ids).to include(plain_boost.id.to_s)
      expect(ids).to_not include(boost.id.to_s)
      nested = response.parsed_body.filter_map { |status| status['reblog'] }.pluck('id')
      expect(nested).to_not include(listing.status_id.to_s)
    end

    it 'removes the share from a follower home feed' do
      listing = listing_for(seller, state: 'active')
      boost = share(listing.status)
      listing.update!(state: 'hidden')

      owner.follow!(booster)
      FeedManager.instance.push_to_home(owner, boost)

      get '/api/v1/timelines/home', headers: headers

      expect(status_ids(response.parsed_body)).to_not include(boost.id.to_s)
    end

    it 'still serves a share of a visible listing with its nested content' do
      listing = listing_for(seller, state: 'active')
      boost = share(listing.status)

      get "/api/v1/statuses/#{boost.id}"

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch('reblog').fetch('souq_listing').fetch('state')).to eq('active')
    end
  end

  # A distribution job can be enqueued while the listing is still visible and
  # run only after the masking. Running it must publish nothing to the public
  # streams and insert nothing into a reader feed; ordinary statuses keep their
  # distribution untouched.
  describe 'a distribution task enqueued before the listing was hidden' do
    let(:follower) { Fabricate(:user, current_sign_in_at: Time.now.utc).account }

    before do
      DistributionWorker.clear
      FeedInsertWorker.clear
    end

    def run_distribution
      published = Hash.new { |hash, channel| hash[channel] = [] }
      allow(redis).to receive(:publish) { |channel, message| published[channel] << message }
      DistributionWorker.jobs.each { |job| DistributionWorker.new.perform(*job['args']) }
      published
    end

    it 'does not publish a hidden listing to the public streams' do
      listing = listing_for(seller, state: 'active')
      follower.follow!(seller)

      DistributionWorker.perform_async(listing.status_id) # queued while still visible
      listing.update!(state: 'hidden') # masked before the job runs

      published = run_distribution

      expect(published).to be_empty
      expect(FeedInsertWorker.jobs).to be_empty
    end

    it 'does not insert a hidden listing into a home feed when the pending job runs after masking' do
      listing = listing_for(seller, state: 'active')
      follower.follow!(seller)

      FeedInsertWorker.perform_async(listing.status_id, follower.id, 'home')
      listing.update!(state: 'hidden')

      FeedInsertWorker.jobs.each { |job| FeedInsertWorker.new.perform(*job['args']) }

      expect(redis.zscore(FeedManager.instance.key(:home, follower.id), listing.status_id)).to be_nil
    end

    it 'still distributes an ordinary public status' do
      status = Fabricate(:status, account: seller, visibility: :public)
      follower.follow!(seller)

      DistributionWorker.perform_async(status.id)

      published = run_distribution

      expect(published['timeline:public']).to be_present
    end
  end
end
