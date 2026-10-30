# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/souq_proof'

RSpec.describe 'SOUQ atomic creation proof', type: :request, use_transactional_tests: false do
  let(:account) { Fabricate(:user).account }

  before do
    Status.connection.create_table(:souq_proof_records) do |table|
      table.bigint :status_id, null: false, index: { unique: true }
      table.boolean :transaction_open, null: false
      table.string :transaction_id, null: false
    end
    SouqProof::Record.reset_column_information
    SouqProof.install!
    Souq::Current.reset
    account
    DistributionWorker.clear
  end

  after do
    Souq::Current.reset
    SouqProof.uninstall!
    Status.connection.drop_table(:souq_proof_records, if_exists: true)
    # These examples deliberately commit. Restore the dedicated test database.
    DatabaseCleaner.clean
    Rails.application.load_seed
    Setting.registrations_mode = 'open'
  end

  def post_status(**options)
    PostStatusService.new.call(account, { text: 'SOUQ atomic proof', visibility: :public }.merge(options))
  end

  def draft
    Souq::Current.listing_draft = { fail: false }
  end

  it '1 creates one status and one proof in the same transaction' do
    draft
    transaction_ids = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      next unless payload[:sql].include?('INSERT INTO "statuses"')

      transaction_ids << Status.connection.select_value('SELECT txid_current()').to_s
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      expect { post_status }.to change(Status, :count).by(1).and change(SouqProof::Record, :count).by(1)
    end
    expect(SouqProof::Record.sole.transaction_open).to be(true)
    expect(transaction_ids).to eq([SouqProof::Record.sole.transaction_id])
  end

  it '2 rolls back both records and enqueues no DistributionWorker on callback failure' do
    Souq::Current.listing_draft = { fail: true }
    expect { post_status }.to raise_error(SouqProof::CreationError, 'proof callback rejected listing')
    expect(Status.count).to eq(0)
    expect(SouqProof::Record.count).to eq(0)
    expect(DistributionWorker.jobs).to be_empty
  end

  it '3 commits before real inline fan-out and exposes the proof to another connection' do
    draft
    observations = []
    allow(FanOutOnWriteService).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap do |service|
        allow(service).to receive(:call).and_wrap_original do |call, status, **options|
          visible = Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              SouqProof::Record.exists?(status_id: status.id)
            end
          end.value
          observations << [Status.connection.transaction_open?, visible]
          call.call(status, **options)
        end
      end
    end
    Sidekiq::Testing.inline! { post_status }
    expect(observations).to eq([[false, true]])
  end

  it '4 publishes the test field to Redis and includes it in both real serializers' do
    draft
    allow(redis).to receive(:publish).and_call_original
    status = nil
    Sidekiq::Testing.inline! { status = post_status }
    expect(redis).to have_received(:publish).with('timeline:public', anything) do |_channel, message|
      envelope = JSON.parse(message)
      expect(envelope.fetch('event')).to eq('update')
      expect(envelope.fetch('payload').fetch('souq_proof')).to be(true)
    end
    [REST::StatusSerializer, REST::ShallowStatusSerializer].each do |serializer|
      json = serialized_record_json(status, serializer, options: { scope: nil, scope_name: :current_user })
      expect(json.fetch('souq_proof')).to be(true)
    end
  end

  it '5 reuses one status and one proof for the same idempotency key' do
    draft
    key = SecureRandom.uuid
    first = post_status(idempotency: key)
    second = post_status(idempotency: key)
    expect(second.id).to eq(first.id)
    expect(Status.count).to eq(1)
    expect(SouqProof::Record.count).to eq(1)
  end

  it '6 leaves an ordinary status unchanged without a listing draft' do
    status = post_status
    expect(Status.count).to eq(1)
    expect(SouqProof::Record.count).to eq(0)
    [REST::StatusSerializer, REST::ShallowStatusSerializer].each do |serializer|
      json = serialized_record_json(status, serializer, options: { scope: nil, scope_name: :current_user })
      expect(json).to_not have_key('souq_proof')
    end
  end

  it '7a resets Current after a real Rack request before the next request' do
    owner = account
    callback = lambda do
      Souq::Current.listing_draft = { fail: false }
      PostStatusService.new.call(owner, text: 'Request boundary proof', visibility: :public)
    end
    controller = Souq::Api::V1::HealthController
    controller.set_callback(:process_action, :before, callback)
    result = Rack::MockRequest.new(Rails.application).get('/api/v1/souq/health', 'REMOTE_ADDR' => '127.0.0.1')
    expect(result.status).to eq(200)
    expect(Souq::Current.listing_draft).to be_nil
    controller.skip_callback(:process_action, :before, callback)
    expect(Rack::MockRequest.new(Rails.application).get('/api/v1/souq/health', 'REMOTE_ADDR' => '127.0.0.1').status).to eq(200)
    expect(SouqProof::Record.count).to eq(1)
  ensure
    controller&.skip_callback(:process_action, :before, callback, raise: false)
  end

  it '7b resets Current between real Sidekiq Rails reloader boundaries' do
    status = post_status
    reloader = Sidekiq::Rails::Reloader.new
    reloader.call do
      draft
      DistributionWorker.new.perform(status.id)
    end
    expect(Souq::Current.listing_draft).to be_nil
    reloader.call do
      expect(Souq::Current.listing_draft).to be_nil
      DistributionWorker.new.perform(status.id)
    end
    expect(SouqProof::Record.count).to eq(0)
  end
end
