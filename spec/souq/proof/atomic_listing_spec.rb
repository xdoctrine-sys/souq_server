# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/souq_proof'
require_relative '../support/taxonomy'

RSpec.describe 'SOUQ atomic creation proof', if: ENV['SOUQ_COMMIT_PROOF'] == '1', type: :request, use_transactional_tests: false do
  include_context 'with API authentication', oauth_scopes: 'write write:statuses'

  let(:account) { user.account }
  let!(:roles_before) { UserRole.order(:id).pluck(:id, :name) }
  let!(:category) { Fabricate(:souq_category, code: 'proof_cars', hashtag: 'proofcars', name_en: 'Proof cars', name_ar: 'سيارات') }

  before do
    Status.connection.create_table(:souq_proof_records) do |table|
      table.bigint :status_id, null: false, index: { unique: true }
      table.boolean :transaction_open, null: false
      table.string :transaction_id, null: false
    end
    SouqProof::Record.reset_column_information
    SouqProof.fail_next = false
    SouqProof.install!
    Souq::Current.reset
    account
    DistributionWorker.clear
  end

  after do
    Souq::Current.reset
    SouqProof.uninstall!
    Status.connection.drop_table(:souq_proof_records, if_exists: true)
    SouqProof.cleanup!(account)
    Souq::Listing.where(category_id: category.id).delete_all
    category.destroy!
    # Every real-commit example must preserve seeded role identities.
    expect(UserRole.order(:id).pluck(:id, :name)).to eq(roles_before) # rubocop:disable RSpec/ExpectInHook
  end

  # Goes through the real production path: Souq::Listings::Create validates the
  # request, stores the normalized draft in Souq::Current and calls the real
  # PostStatusService, whose Status.after_create callback inserts the listing.
  def create_listing(idempotency: nil, status: {}, listing: {})
    Souq::Listings::Create.call(
      account,
      status: { text: 'SOUQ atomic proof', visibility: 'public' }.merge(status),
      listing: { category: category.code, title: 'SOUQ atomic proof', price_mode: 'fixed', price: '1250.00' }.merge(listing),
      idempotency:
    )
  end

  def post_plain_status
    PostStatusService.new.call(account, text: 'SOUQ atomic proof', visibility: :public)
  end

  # Every attribute declared on Souq::Current must be empty after the request
  # or the job, not only the one this proof happens to set. The set of names is
  # asserted so that a new attribute cannot be added without being covered.
  def expect_current_cleared(context)
    names = Souq::Current.defaults.keys
    expect(names).to contain_exactly(:listing_draft, :listing_update, :taxonomy_snapshot)
    names.each do |name|
      expect(Souq::Current.public_send(name)).to be_nil, "Souq::Current.#{name} was not reset #{context}"
    end
  end

  it '1 creates one status and one listing in the same transaction' do
    transaction_ids = Hash.new { |hash, key| hash[key] = [] }
    callback = lambda do |_name, _start, _finish, _id, payload|
      table = if payload[:sql].include?('INSERT INTO "statuses"')
                :status
              elsif payload[:sql].include?('INSERT INTO "souq_listings"')
                :listing
              end
      transaction_ids[table] << Status.connection.select_value('SELECT txid_current()').to_s if table
    end

    status = nil
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      expect { status = create_listing }.to change(Status, :count).by(1).and change(Souq::Listing, :count).by(1)
    end

    expect(transaction_ids[:listing]).to be_present
    expect(transaction_ids[:listing]).to eq(transaction_ids[:status])
    expect(transaction_ids[:status]).to eq([SouqProof::Record.sole.transaction_id])
    expect(Souq::Listing.sole.status_id).to eq(status.id)
  end

  it '2 rolls back the status and the listing and enqueues no DistributionWorker on callback failure' do
    SouqProof.fail_next = true

    expect { create_listing }.to raise_error(SouqProof::CreationError, 'proof callback rejected listing')

    expect(Status.count).to eq(0)
    expect(Souq::Listing.count).to eq(0)
    expect(SouqProof::Record.count).to eq(0)
    expect(DistributionWorker.jobs).to be_empty
  end

  it '3 commits before real inline fan-out and exposes the listing to another connection' do
    observations = []
    allow(FanOutOnWriteService).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap do |service|
        allow(service).to receive(:call).and_wrap_original do |call, status, **options|
          visible = Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              Souq::Listing.exists?(status_id: status.id)
            end
          end.value
          observations << [Status.connection.transaction_open?, visible]
          call.call(status, **options)
        end
      end
    end

    Sidekiq::Testing.inline! { create_listing }

    expect(observations).to eq([[false, true]])
  end

  it '4 publishes the listing on timeline:public for the streaming API' do
    allow(redis).to receive(:publish).and_call_original

    status = nil
    Sidekiq::Testing.inline! { status = create_listing }

    listing = Souq::Listing.sole
    expect(redis).to have_received(:publish).with('timeline:public', anything) do |_channel, message|
      envelope = JSON.parse(message)
      expect(envelope.fetch('event')).to eq('update')
      expect(envelope.fetch('payload').fetch('souq_listing')).to include(
        'id' => listing.id.to_s,
        'title' => 'SOUQ atomic proof',
        'state' => 'active'
      )
    end
    expect(status.souq_listing).to eq(listing)
  end

  it '5 reuses one status and one listing for the same idempotency key' do
    key = SecureRandom.uuid
    first = create_listing(idempotency: key)
    second = create_listing(idempotency: key)

    expect(second.id).to eq(first.id)
    expect(Status.count).to eq(1)
    expect(Souq::Listing.count).to eq(1)
    expect(SouqProof::Record.count).to eq(1)
  end

  it '6 leaves an ordinary status without a listing draft unchanged' do
    status = post_plain_status

    expect(Status.count).to eq(1)
    expect(Souq::Listing.count).to eq(0)
    expect(status.souq_listing).to be_nil
    expect(SouqProof::Record.count).to eq(0)
    expect(Souq::Current.listing_draft).to be_nil
  end

  it '6b creates no listing for a plain status posted through the Mastodon API' do
    post '/api/v1/statuses', params: { status: 'Plain API status', visibility: 'public' }, headers: headers

    expect(response).to have_http_status(200)
    expect(Status.count).to eq(1)
    expect(Souq::Listing.count).to eq(0)
    expect(Souq::Current.listing_draft).to be_nil
  end

  it '7a resets Current after a real Rack request before the next request' do
    owner = account
    category_code = category.code
    # The callback runs with instance_exec inside the controller, so it may only
    # use captured locals and constants, never the example's helper methods.
    callback = lambda do
      Souq::Listings::Create.call(
        owner,
        status: { text: 'SOUQ atomic proof', visibility: 'public' },
        listing: { category: category_code, title: 'SOUQ atomic proof', price_mode: 'fixed', price: '1250.00' }
      )
      Souq::Current.taxonomy_snapshot = Souq::TaxonomyCache.snapshot
    end
    controller = Souq::Api::V1::HealthController
    controller.set_callback(:process_action, :before, callback)
    result = Rack::MockRequest.new(Rails.application).get('/api/v1/souq/health', 'REMOTE_ADDR' => '127.0.0.1')
    expect(result.status).to eq(200)
    expect_current_cleared('after the Rack request')
    controller.skip_callback(:process_action, :before, callback)
    second = Rack::MockRequest.new(Rails.application).get('/api/v1/souq/health', 'REMOTE_ADDR' => '127.0.0.1')
    expect(second.status).to eq(200)
    expect_current_cleared('after the next Rack request')
    expect(Souq::Listing.count).to eq(1)
    expect(SouqProof::Record.count).to eq(1)
  ensure
    controller&.skip_callback(:process_action, :before, callback, raise: false)
  end

  it '7b resets Current between real Sidekiq Rails reloader boundaries' do
    status = create_listing
    reloader = Sidekiq::Rails::Reloader.new
    reloader.call do
      Souq::Current.listing_draft = { proof: true }
      DistributionWorker.new.perform(status.id)
    end
    expect_current_cleared('after the Sidekiq job')
    reloader.call do
      expect_current_cleared('before the next Sidekiq job')
      DistributionWorker.new.perform(status.id)
    end
    expect(SouqProof::Record.count).to eq(1)
  end
end
