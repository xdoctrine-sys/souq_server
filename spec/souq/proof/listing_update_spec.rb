# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'

# Proves, with real commits (rule 15), that a SOUQ listing edit is written
# inside the transaction UpdateStatusService opens around `@status.save!`, so
# that the distribution jobs enqueued after the commit already carry the new
# content: at the very moment DistributionWorker and
# ActivityPub::StatusUpdateDistributionWorker are called, a second database
# connection reads the new status text and the new listing fields.
#
# This file is the red/green witness for the T11a correction. On `1c3fcf9804`
# (`Souq::Listings::Update` wrapping `UpdateStatusService` in its own
# `ApplicationRecord.transaction`) the same example (a) fails, because the
# second connection still reads the old text, title, price and state while the
# broadcast is enqueued.
RSpec.describe 'SOUQ listing update proof', if: ENV['SOUQ_COMMIT_PROOF'] == '1', type: :request, use_transactional_tests: false do
  include_context 'with API authentication', oauth_scopes: 'read read:statuses write write:statuses'

  let(:account) { user.account }

  before do
    Fabricate(:souq_category, code: 'proof_cars', hashtag: 'proofcars', name_en: 'Proof cars', name_ar: 'سيارات')
    Fabricate(:souq_location, code: 'proof_doha', name_en: 'Proof Doha', name_ar: 'الدوحة')
    Souq::Current.reset
    DistributionWorker.clear
    ActivityPub::StatusUpdateDistributionWorker.clear
    LocalNotificationWorker.clear
    PushUpdateWorker.clear
    account
  end

  after do
    Souq::Current.reset
    cleanup!
  end

  # Real production path, exactly like the controller: Souq::Listings::Create
  # validates the request, stores the normalized draft and calls the real
  # PostStatusService.
  def create_listing(text: 'SOUQ proof listing', **listing)
    status = Souq::Listings::Create.call(
      account,
      status: { text: text, visibility: 'public' },
      listing: { category: 'proof_cars', title: 'Proof listing title', price_mode: 'fixed', price: '1250.00' }.merge(listing)
    )
    Souq::Listing.find_by!(status_id: status.id)
  end

  # Reads the committed state from a *second* database connection, so an
  # uncommitted write is invisible here.
  def snapshot_from_another_connection(status_id)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        status = Status.find_by(id: status_id)
        next nil if status.nil?

        listing = Souq::Listing.find_by(status_id: status_id)
        {
          text: status.text,
          title: listing&.title,
          price_minor: listing&.price_minor,
          location: listing&.location&.code,
          state: listing&.state,
        }
      end
    end.value
  end

  # Records what the second connection can read at the very moment each
  # distribution job is enqueued. The original implementation is always called,
  # so the queues still fill up normally.
  def observe_distribution_jobs
    # Drops the jobs enqueued by the listing creation, so that only the jobs
    # enqueued by the edit under test are observed.
    DistributionWorker.clear
    ActivityPub::StatusUpdateDistributionWorker.clear

    observations = []

    allow(DistributionWorker).to receive(:perform_async).and_wrap_original do |original, *args|
      observations << [:distribution, args, snapshot_from_another_connection(args.first)]
      original.call(*args)
    end

    allow(ActivityPub::StatusUpdateDistributionWorker).to receive(:perform_async).and_wrap_original do |original, *args|
      observations << [:activity_pub, args, snapshot_from_another_connection(args.first)]
      original.call(*args)
    end

    observations
  end

  def cleanup!
    ApplicationRecord.transaction do
      Souq::Listing.where(account_id: account.id).delete_all
      Status.unscoped.where(account_id: account.id).destroy_all
      # Conversations and access tokens have no cascading foreign key here.
      Conversation.where(parent_account_id: account.id).delete_all
      Doorkeeper::AccessToken.where(resource_owner_id: User.where(account_id: account.id).select(:id)).delete_all
      account.destroy!
    end

    Souq::Category.where(code: 'proof_cars').delete_all
    Souq::Location.where(code: 'proof_doha').delete_all
  end

  it '(a) PUT with a new text and a new price is already visible from another connection when it broadcasts' do
    listing = create_listing
    observations = observe_distribution_jobs

    put "/api/v1/souq/listings/#{listing.id}",
        params: {
          status: { status: 'Updated proof listing text' },
          listing: { title: 'Updated proof title', price_mode: 'fixed', price: '2000.00', location: 'proof_doha' },
        },
        headers: headers

    expect(response).to have_http_status(200)
    expect(observations.map(&:first)).to eq(%i(distribution activity_pub))
    expect(observations.map(&:last).uniq).to eq(
      [{
        text: 'Updated proof listing text',
        title: 'Updated proof title',
        price_minor: 200_000,
        location: 'proof_doha',
        state: 'active',
      }]
    )
    expect(listing.status.reload.edited_at).to be_present
  end

  it '(b) PUT without a text change is already visible from another connection when it broadcasts' do
    listing = create_listing
    original_text = listing.status.reload.text
    observations = observe_distribution_jobs

    put "/api/v1/souq/listings/#{listing.id}",
        params: { listing: { title: 'Refreshed proof title', price_mode: 'negotiable', price: '3000.00' } },
        headers: headers

    expect(response).to have_http_status(200)
    expect(observations.map(&:first)).to eq([:distribution])
    expect(observations.first[1]).to eq([listing.status_id, { 'update' => true, 'skip_notifications' => true }])
    expect(observations.first.last).to eq(
      text: original_text,
      title: 'Refreshed proof title',
      price_minor: 300_000,
      location: nil,
      state: 'active'
    )
  end

  it '(c) POST state sold is already visible from another connection when it broadcasts' do
    listing = create_listing
    original_text = listing.status.reload.text
    observations = observe_distribution_jobs

    post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'sold' }, headers: headers

    expect(response).to have_http_status(200)
    expect(observations.map(&:first)).to eq([:distribution])
    expect(observations.first[1]).to eq([listing.status_id, { 'update' => true, 'skip_notifications' => true }])
    expect(observations.first.last).to eq(
      text: original_text,
      title: 'Proof listing title',
      price_minor: 125_000,
      location: nil,
      state: 'sold'
    )
  end

  # Asserts the streaming message carries the committed listing: the event, the
  # text and the SOUQ fields (state, title, price).
  def expect_listing_update_payload(message)
    json = JSON.parse(message)
    expect(json.fetch('event')).to eq('status.update')
    expect(json.fetch('payload').fetch('content')).to include('SOUQ proof listing')
    expect(json.fetch('payload').fetch('souq_listing')).to include(
      'state' => 'sold',
      'title' => 'Proof listing title'
    )
    expect(json.fetch('payload').fetch('souq_listing').fetch('price')).to include(
      'minor' => 125_000,
      'amount' => '1250.00'
    )
  end

  # Proves the streaming payload itself, not just the event name: the messages
  # published on `timeline:public` and on the owner's own `timeline:<id>` carry
  # the committed text and the committed `souq_listing` (state, title, price).
  it '(f) publishes the committed listing content on the public and owner streams' do
    listing = create_listing
    redis.set("subscribed:timeline:#{account.id}", 1)

    published = Hash.new { |hash, channel| hash[channel] = [] }
    allow(redis).to receive(:publish) { |channel, message| published[channel] << message }

    DistributionWorker.clear
    PushUpdateWorker.clear

    post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'sold' }, headers: headers
    expect(response).to have_http_status(200)

    DistributionWorker.jobs.each { |job| DistributionWorker.new.perform(*job['args']) }
    PushUpdateWorker.jobs.each { |job| PushUpdateWorker.new.perform(*job['args']) }

    expect(published['timeline:public']).to be_present
    expect(published["timeline:#{account.id}"]).to be_present
    expect_listing_update_payload(published['timeline:public'].last)
    expect_listing_update_payload(published["timeline:#{account.id}"].last)
  end

  it '(d) POST state with the state already in place enqueues no job' do
    listing = create_listing
    listing.update!(state: 'sold', sold_at: Time.current)
    observations = observe_distribution_jobs

    post "/api/v1/souq/listings/#{listing.id}/state", params: { state: 'sold' }, headers: headers

    expect(response).to have_http_status(200)
    expect(observations).to be_empty
    expect(DistributionWorker.jobs).to be_empty
    expect(ActivityPub::StatusUpdateDistributionWorker.jobs).to be_empty
  end

  it '(e) rolls the text and the listing back together when a later step of the edit fails' do
    listing = create_listing
    original_text = listing.status.reload.text
    observe_distribution_jobs

    # The failure is injected right after the listing write, inside the status
    # transaction: the real Souq::Listing update runs first, then the step
    # raises, and the whole transaction must roll back.
    allow(Souq::Listings::Update).to receive(:apply!).and_wrap_original do |original, status, draft|
      original.call(status, draft)
      raise 'proof rejected the listing update'
    end

    expect do
      Souq::Listings::Update.call(
        listing,
        status_params: { text: 'Discarded proof text' },
        listing_params: { title: 'Discarded proof title', price_mode: 'fixed', price: '9999.00' }
      )
    end.to raise_error(RuntimeError, 'proof rejected the listing update')

    expect(snapshot_from_another_connection(listing.status_id)).to eq(
      text: original_text,
      title: 'Proof listing title',
      price_minor: 125_000,
      location: nil,
      state: 'active'
    )
    expect(listing.reload.title).to eq('Proof listing title')
    expect(listing.status.reload.text).to eq(original_text)
    expect(listing.status.reload.edited_at).to be_nil
    expect(StatusEdit.where(status_id: listing.status_id).count).to eq(0)
    expect(DistributionWorker.jobs).to be_empty
    expect(ActivityPub::StatusUpdateDistributionWorker.jobs).to be_empty
    expect(Souq::Current.listing_update).to be_nil
  end
end
