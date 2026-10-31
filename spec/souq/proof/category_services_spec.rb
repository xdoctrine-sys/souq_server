# frozen_string_literal: true

require 'rails_helper'
require 'timeout'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'

RSpec.describe 'SOUQ category services at real commit', if: ENV['SOUQ_COMMIT_PROOF'] == '1', use_transactional_tests: false do # rubocop:disable RSpec/DescribeClass
  let(:pool) { ActiveRecord::Base.connection_pool }
  let(:created_ids) { [] }
  let(:workers) { [] }
  let!(:account) { Fabricate(:account) }
  let!(:a) { category }
  let!(:b) { category }
  let!(:previous_version) { read_taxonomy_version }

  before do
    write_taxonomy_version(5)
    Souq::TaxonomyCache.reset!
  end

  after do
    workers.each { |worker| worker.join(10) }
    Souq::AuditLog.where(account_id: account.id).delete_all
    Souq::Listing.where(account_id: account.id).delete_all
    Status.unscoped.where(account_id: account.id).destroy_all
    account.destroy!
    Souq::Category.where(id: created_ids).order(depth: :desc).each(&:destroy!)
    if previous_version
      write_taxonomy_version(previous_version)
    else
      clear_taxonomy_version
    end
    Souq::TaxonomyCache.reset!
  end

  def category(parent: nil)
    Fabricate(:souq_category, parent: parent, position: Souq::Category.where(parent_id: parent&.id).count).tap { |row| created_ids << row.id }
  end

  def move(node, parent, lock_version: node.lock_version)
    Souq::Categories::Move.call(account: account, category: node, new_parent: parent, lock_version: lock_version)
  end

  def worker
    thread = Thread.new do
      pool.with_connection do
        yield
      ensure
        Souq::Current.reset
      end
    rescue => e
      e
    end
    workers << thread
    thread
  end

  def result(thread)
    Timeout.timeout(15) { thread.value }
  end

  def opposite_moves(optimistic:)
    ready = Queue.new
    go = Queue.new
    threads = [[a, b], [b, a]].map do |node, parent|
      worker do
        ready << true
        go.pop
        move(node, parent, lock_version: optimistic ? node.lock_version : nil)
      end
    end
    2.times { Timeout.timeout(10) { ready.pop } }
    2.times { go << true }
    threads.map { |thread| result(thread) }
  end

  it '(a1) serializes opposite moves without optimistic locking with exactly one CycleError' do
    results = opposite_moves(optimistic: false)
    classes = results.map(&:class)
    expect(results.count { |item| item.is_a?(Souq::Categories::Base::Result) && item.changed? }).to eq(1), classes.inspect
    expect(results.count { |item| item.is_a?(Souq::Categories::CycleError) }).to eq(1), classes.inspect
    expect(results.grep(Souq::Categories::ValidationError)).to be_empty, classes.inspect
    expect([a.reload.ancestor_ids.include?(b.id), b.reload.ancestor_ids.include?(a.id)].count(true)).to eq(1)
  end

  it '(a2) moves the same node concurrently to different parents with exactly one ConflictError' do
    other_parent = category
    expected_version = a.reload.lock_version
    ready = Queue.new
    go = Queue.new
    threads = [b, other_parent].map do |parent|
      worker do
        ready << true
        go.pop
        move(a, parent, lock_version: expected_version)
      end
    end
    2.times { Timeout.timeout(10) { ready.pop } }
    2.times { go << true }
    results = threads.map { |thread| result(thread) }
    classes = results.map(&:class)
    expect(results.count { |item| item.is_a?(Souq::Categories::Base::Result) && item.changed? }).to eq(1), classes.inspect
    expect(results.count { |item| item.is_a?(Souq::Categories::ConflictError) }).to eq(1), classes.inspect
    expect([b.id, other_parent.id]).to include(a.reload.parent_id)
    expect(a.lock_version).to eq(expected_version + 1)
  end

  it '(a3) rejects a stale version after another move shifts the node as a sibling' do
    other_parent = category
    expected_version = b.reload.lock_version
    old_position = b.position
    move(a, other_parent)
    expect(b.reload.position).to eq(old_position - 1)
    expect(b.lock_version).to eq(expected_version + 1)
    before = Souq::Category.order(:id).pluck(:id, :parent_id, :ancestor_ids, :depth, :position, :lock_version)
    version = read_taxonomy_version
    audit_count = Souq::AuditLog.where(account_id: account.id).count
    expect { move(b, other_parent, lock_version: expected_version) }.to raise_error(Souq::Categories::ConflictError)
    expect(Souq::Category.order(:id).pluck(:id, :parent_id, :ancestor_ids, :depth, :position, :lock_version)).to eq(before)
    expect(read_taxonomy_version).to eq(version)
    expect(Souq::AuditLog.where(account_id: account.id).count).to eq(audit_count)
  end

  it 'serializes opposite moves with optimistic versions and either typed conflict or cycle rejection' do
    results = opposite_moves(optimistic: true)
    classes = results.map(&:class)
    expect(results.count { |item| item.is_a?(Souq::Categories::Base::Result) && item.changed? }).to eq(1), classes.inspect
    expect(results.count { |item| item.is_a?(Souq::Categories::ConflictError) || item.is_a?(Souq::Categories::CycleError) }).to eq(1), classes.inspect
    expect([a.reload.ancestor_ids.include?(b.id), b.reload.ancestor_ids.include?(a.id)].count(true)).to eq(1), classes.inspect
  end

  def expect_shared_lock
    held = Queue.new
    release = Queue.new
    holder = worker do
      ApplicationRecord.transaction do
        Souq::Category.connection.execute("SELECT pg_advisory_xact_lock(hashtext('souq_categories_tree'))")
        held << true
        release.pop
      end
    end
    Timeout.timeout(10) { held.pop }
    pid_queue = Queue.new
    operations = [
      lambda do
        item = Souq::Categories::Create.call(account: account, parent: b, code: "proof_created_#{a.id}", name_en: 'Category', name_ar: 'Category').category
        created_ids << item.id
        item
      end,
      -> { move(a, b) },
      -> { Souq::Categories::Reorder.call(account: account, parent: b, ordered_ids: []) },
    ]
    threads = operations.map do |operation|
      worker do
        pid_queue << Souq::Category.connection.select_value('SELECT pg_backend_pid()')
        operation.call
      end
    end
    pids = Array.new(3) { Timeout.timeout(10) { pid_queue.pop } }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    waiting = 0
    loop do
      waiting = Souq::Category.connection.select_value(<<~SQL.squish).to_i
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'advisory' AND NOT granted
          AND pid IN (#{pids.join(',')})
          AND classid = CASE WHEN hashtext('souq_categories_tree') < 0 THEN 4294967295 ELSE 0 END
          AND objid = (hashtext('souq_categories_tree')::bigint & 4294967295)
          AND objsubid = 1
      SQL
      break if waiting == 3 || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
    expect(waiting).to eq(3)
    release << true
    result(holder)
    results = threads.map { |thread| result(thread) }
    # Reorder peut observer les nouveaux enfants : le conflit type est valide.
    expect(results[0]).to be_a(Souq::Category)
    expect(results[1]).to be_a(Souq::Categories::Base::Result)
    expect([Souq::Categories::Base::Result, Souq::Categories::ConflictError]).to include(results[2].class)
    expect(a.reload.parent_id).to eq(b.id)
    expect(b.children.order(:position).pluck(:position)).to eq([0, 1])
  ensure
    release << true if release && holder&.alive?
  end

  it '(b) proves Create, Move and Reorder wait for the exact shared advisory lock' do
    expect_shared_lock
  end

  it 'keeps a snapshot label no newer than its content during a concurrent committed Move' do
    allow(Souq::TaxonomyCache).to receive(:load_tree).and_wrap_original do |original|
      loaded = original.call
      outcome = result(worker { move(a, b) })
      raise outcome if outcome.is_a?(Exception)

      loaded
    end
    snapshot = Souq::TaxonomyCache.snapshot
    content_version = snapshot.category(a.code)[:parent_id] == b.id ? 6 : 5
    expect(snapshot.version).to be <= content_version
    expect(read_taxonomy_version).to eq(6)
    allow(Souq::TaxonomyCache).to receive(:load_tree).and_call_original
    Souq::Current.reset
    fresh = Souq::TaxonomyCache.snapshot
    expect(fresh.version).to eq(6)
    expect(fresh.category(a.code)[:path]).to eq([b.code, a.code])
  end

  it 'invalidates in the same scope only after commit and exposes the path without changing a listing category id' do
    listing = Fabricate(:souq_listing, account: account, status: Fabricate(:status, account: account), category: a, category_code: a.code)
    first = Souq::TaxonomyCache.snapshot
    ApplicationRecord.transaction do
      move(a, b)
      expect(Souq::Current.taxonomy_snapshot).to equal(first)
    end
    expect(Souq::Current.taxonomy_snapshot).to be_nil
    expect(listing.reload.category_id).to eq(a.id)
    expect(Souq::REST::ListingSerializer.new(listing).as_json.fetch(:category).fetch(:path)).to eq([b.code, a.code])
    2.times do
      Souq::TaxonomyCache.reset!
      expect(Souq::TaxonomyCache.snapshot.version).to eq(6)
      expect(Souq::TaxonomyCache.snapshot.category(a.code)[:parent_id]).to eq(b.id)
    end
  end

  def expect_rollback_and_refusal
    first = Souq::TaxonomyCache.snapshot
    before = Souq::Category.order(:id).pluck(:id, :parent_id, :ancestor_ids, :depth, :position, :lock_version)
    ApplicationRecord.transaction do
      move(a, b)
      raise ActiveRecord::Rollback
    end
    expect(Souq::Current.taxonomy_snapshot).to equal(first)
    expect(read_taxonomy_version).to eq(5)
    expect(Souq::Category.order(:id).pluck(:id, :parent_id, :ancestor_ids, :depth, :position, :lock_version)).to eq(before)
    expect(Souq::AuditLog.where(account_id: account.id)).to be_empty
    Souq::Categories::Move.call(account: account, category: a, new_parent: nil, lock_version: a.reload.lock_version, position: a.position)
    expect(Souq::Current.taxonomy_snapshot).to equal(first)

    child = category(parent: a)
    allow(Souq::AuditLog).to receive(:create!).and_wrap_original do |original, **attributes|
      log = original.call(**attributes)
      Souq::Category.connection.execute("UPDATE souq_categories SET ancestor_ids = ARRAY[#{a.id}]::bigint[], depth = 1 WHERE id = #{child.id}")
      log
    end
    before_refusal = Souq::Category.order(:id).pluck(:id, :parent_id, :ancestor_ids, :depth, :position, :lock_version)
    expect { move(a, b) }.to raise_error(Souq::Categories::ValidationError)
    connection = Souq::Category.connection
    expect(connection.select_value('SELECT 1')).to eq(1)
    expect(connection.transaction_open?).to be(false)
    expect(connection.raw_connection.transaction_status).to eq(PG::PQTRANS_IDLE)
    expect(Souq::Category.order(:id).pluck(:id, :parent_id, :ancestor_ids, :depth, :position, :lock_version)).to eq(before_refusal)
    expect(Souq::Current.taxonomy_snapshot).to equal(first)
    expect(read_taxonomy_version).to eq(5)
    expect(a.reload.parent_id).to be_nil
    expect(Souq::AuditLog.where(account_id: account.id)).to be_empty
    puts 'Apres refus: SELECT 1=1, transaction_open=false, PG=IDLE, arbre/positions/locks inchanges, version=5, audit=0' # rubocop:disable RSpec/Output, Rails/Output
  end

  it 'does not invalidate or increment on rollback, no effect, or deferred trigger failure' do
    expect_rollback_and_refusal
  end
end
