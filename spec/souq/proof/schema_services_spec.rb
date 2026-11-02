# frozen_string_literal: true

require 'rails_helper'
require 'timeout'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'
require_relative '../support/attributes'

# Real-commit proof of the T6 rule write services (design section 3.4, prompt
# section 3). Nothing here is transactional: every write really commits, and
# the fixtures are removed afterwards.
#
# It proves three things the unit specs cannot: the writers take the very same
# advisory lock as the T2 category tree, the subtree revalidation aborts the
# rule, the version bump and the audit row together, and the request snapshot
# is invalidated only after a successful commit.
#
# Run with SOUQ_COMMIT_PROOF=1.
RSpec.describe 'SOUQ schema rule services at real commit', if: ENV['SOUQ_COMMIT_PROOF'] == '1', use_transactional_tests: false do # rubocop:disable RSpec/DescribeClass
  let(:pool) { ActiveRecord::Base.connection_pool }
  let(:workers) { [] }
  let!(:account) { Fabricate(:account) }
  let!(:previous_version) { read_taxonomy_version }

  let(:vehicles) { category('t6proofvehicles') }
  let(:cars) { category('t6proofcars') }
  let(:transaction_type) { definition('t6prooftransaction') }
  let(:slot_a) { definition('t6proofslota') }
  let(:slot_b) { definition('t6proofslotb') }
  let(:slot_c) { definition('t6proofslotc') }
  let(:slot_x) { definition('t6proofslotx') }

  before do
    build_proof_schema
    write_taxonomy_version(5)
    Souq::TaxonomyCache.reset!
  end

  after do
    workers.each { |worker| worker.join(10) }
    cleanup_proof_schema
    Souq::AuditLog.where(account_id: account.id).delete_all
    account.destroy!
    previous_version ? write_taxonomy_version(previous_version) : clear_taxonomy_version
    Souq::TaxonomyCache.reset!
  end

  # --- fixtures ------------------------------------------------------------

  def code_prefix
    't6proof'
  end

  def build_proof_schema
    root = build_category("#{code_prefix}vehicles", 'Vehicles', 'مركبات')
    child = build_category("#{code_prefix}cars", 'Cars', 'سيارات', parent: root)
    option_definition = build_definition("#{code_prefix}transaction", 0, 'single_option')
    build_definition("#{code_prefix}year", 1, 'integer')
    build_definition("#{code_prefix}slota", 2, 'integer')
    build_definition("#{code_prefix}slotb", 3, 'integer')
    build_definition("#{code_prefix}slotc", 4, 'integer')
    slot_x_row = build_definition("#{code_prefix}slotx", 5, 'integer')

    Fabricate(:souq_attribute_option, definition: option_definition, code: "#{code_prefix}sale", name_en: 'sale', name_ar: 'sale')
    Fabricate(:souq_attribute_option, definition: option_definition, code: "#{code_prefix}rent", name_en: 'rent', name_ar: 'rent')

    Fabricate(:souq_category_attribute, category: root, definition: option_definition, mode: 'enable', required: true)
    Fabricate(:souq_category_attribute, category: child, definition: option_definition, mode: 'override',
                                        config: { 'allowed_option_codes' => ["#{code_prefix}sale"] })
    Fabricate(:souq_category_attribute, category: child, definition: slot_x_row, mode: 'enable')
  end

  def build_category(code, name_en, name_ar, parent: nil)
    Fabricate(:souq_category, code: code, name_en: name_en, name_ar: name_ar, parent: parent)
  end

  def build_definition(code, position, data_type)
    Fabricate(:souq_attribute_definition, code: code, name_en: code, name_ar: code,
                                          data_type: data_type, position: position)
  end

  def cleanup_proof_schema
    definitions = Souq::AttributeDefinition.where('code LIKE ?', "#{code_prefix}%").pluck(:id)
    categories = Souq::Category.where('code LIKE ?', "#{code_prefix}%").pluck(:id)
    Souq::CategoryAttribute.where(category_id: categories).delete_all
    Souq::AttributeDefinition.where(id: definitions).find_each(&:destroy!)
    Souq::Category.where(id: categories).order(depth: :desc).each(&:destroy!)
  end

  # --- helpers -------------------------------------------------------------

  def category(code)
    Souq::Category.find_by!(code: code)
  end

  def definition(code)
    Souq::AttributeDefinition.find_by!(code: code)
  end

  def connection
    Souq::CategoryAttribute.connection
  end

  def set_rule(category, definition, mode:, config: {}, condition: nil)
    Souq::Schema::Rules::Set.call(account: account, category: category, definition: definition,
                                  mode: mode, config: config, condition: condition)
  end

  def remove_rule(category, definition)
    Souq::Schema::Rules::Remove.call(account: account, category: category, definition: definition)
  end

  def stored_rule(category, definition)
    Souq::CategoryAttribute.find_by(category_id: category.id, definition_id: definition.id)
  end

  def version_now
    Souq::Setting.uncached { Souq::Setting.where(id: 1).pick(:taxonomy_version) }
  end

  def audit_actions
    Souq::AuditLog.where(account_id: account.id).order(:id).pluck(:action)
  end

  def rule_rows
    Souq::CategoryAttribute.order(:id).pluck(:id, :category_id, :definition_id, :mode, :required, :position, :config, :condition)
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
    Timeout.timeout(20) { thread.value }
  end

  def concurrent_sets(definition, configs)
    ready = Queue.new
    go = Queue.new
    threads = configs.map do |config|
      worker do
        ready << true
        go.pop
        set_rule(cars, definition, mode: :enable, config: config)
      end
    end
    configs.size.times { Timeout.timeout(10) { ready.pop } }
    configs.size.times { go << true }
    threads.map { |thread| result(thread) }
  end

  # --- examples ------------------------------------------------------------

  it '(a) serializes two writes on the same rule: one create, one update, two bumps' do
    configs = [{ 'min_value' => 1, 'max_value' => 9 }, { 'min_value' => 1, 'max_value' => 5 }]
    results = concurrent_sets(slot_a, configs)

    expect(results.map(&:changed?)).to eq([true, true])
    expect(audit_actions.sort).to eq(%w(create update))
    expect(version_now).to eq(7)
    expect(Souq::CategoryAttribute.where(category_id: cars.id, definition_id: slot_a.id).count).to eq(1)
    expect(configs).to include(stored_rule(cars, slot_a).config)
  end

  it '(b) treats a concurrent duplicate write as unchanged: one create, a single bump' do
    config = { 'min_value' => 1, 'max_value' => 9 }
    results = concurrent_sets(slot_a, [config, config])

    expect(results.count(&:changed?)).to eq(1)
    expect(audit_actions).to eq(%w(create))
    expect(version_now).to eq(6)
    expect(Souq::CategoryAttribute.where(category_id: cars.id, definition_id: slot_a.id).count).to eq(1)
  end

  it '(c) proves Set and Remove wait for the exact shared advisory lock' do
    results = prove_shared_lock
    classes = results.map(&:class)

    expect(classes).to eq([Souq::Schema::Rules::Base::Result] * 3), classes.inspect
    expect(results.map(&:changed?)).to eq([true, true, true])
    expect(version_now).to eq(8)
    expect(audit_actions.sort).to eq(%w(create create deactivate))
  end

  it '(d) rolls the removal back when a descendant override would lose its inherited rule' do
    first = Souq::TaxonomyCache.snapshot
    version = version_now
    before_rows = rule_rows

    error = nil
    begin
      remove_rule(vehicles, transaction_type)
    rescue Souq::Schema::RuleError => e
      error = e
    end

    expect(error).to be_a(Souq::Schema::RuleError)
    expect(error.issues.map(&:code)).to include('override_without_inherited')
    expect(rule_rows).to eq(before_rows)
    expect(version_now).to eq(version)
    expect(audit_actions).to be_empty
    expect(Souq::Current.taxonomy_snapshot).to equal(first)
    expect(connection.transaction_open?).to be(false)
    expect(connection.raw_connection.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  it '(e) invalidates the snapshot only after commit and keeps it through a rollback' do
    first = Souq::TaxonomyCache.snapshot
    ApplicationRecord.transaction do
      set_rule(cars, slot_a, mode: :enable)
      expect(Souq::Current.taxonomy_snapshot).to equal(first)
    end
    expect(Souq::Current.taxonomy_snapshot).to be_nil
    second = Souq::TaxonomyCache.snapshot
    expect(second.version).to eq(6)

    ApplicationRecord.transaction do
      set_rule(cars, slot_b, mode: :enable)
      raise ActiveRecord::Rollback
    end

    expect(Souq::Current.taxonomy_snapshot).to equal(second)
    expect(version_now).to eq(6)
    expect(stored_rule(cars, slot_b)).to be_nil
  end

  it '(f) keeps a snapshot label no newer than its content during a concurrent committed write' do
    snapshot = nil
    with_commit_during_catalog_load do
      snapshot = Souq::TaxonomyCache.snapshot
      content_version = snapshot.schema(cars.code).codes.include?(slot_a.code) ? 6 : 5
      expect(snapshot.version).to be <= content_version
    end

    expect(version_now).to eq(6)
    Souq::Current.reset
    fresh = Souq::TaxonomyCache.snapshot
    expect(fresh.version).to eq(6)
    expect(fresh.schema(cars.code).codes).to include(slot_a.code)
  end

  it '(g) returns the resolver warnings of the subtree at real commit' do
    dependent = build_definition("#{code_prefix}warned", 6, 'single_option')
    Fabricate(:souq_attribute_option, definition: dependent, code: "#{code_prefix}warnopt",
                                      name_en: 'warned', name_ar: 'warned')

    condition = { 'attribute' => "#{code_prefix}transaction", 'in' => ["#{code_prefix}rent"] }
    result = set_rule(cars, dependent, mode: :enable, condition: condition)

    expect(result.changed?).to be(true)
    warning = result.warnings.find { |entry| entry.code == 'condition_never_true' }
    expect(warning).to be_present
    expect(warning.category).to eq("#{code_prefix}cars")
    expect(warning.attribute).to eq("#{code_prefix}warned")
  end

  # --- lock and interleaving helpers ---------------------------------------

  def lock_key
    'souq_categories_tree'
  end

  def prove_shared_lock
    held = Queue.new
    release = Queue.new
    holder = worker do
      ApplicationRecord.transaction do
        connection.execute("SELECT pg_advisory_xact_lock(hashtext('#{lock_key}'))")
        held << true
        release.pop
      end
    end
    Timeout.timeout(10) { held.pop }

    pid_queue = Queue.new
    operations = [
      -> { set_rule(cars, slot_b, mode: :enable) },
      -> { set_rule(vehicles, slot_c, mode: :enable) },
      -> { remove_rule(cars, slot_x) },
    ]
    threads = operations.map do |operation|
      worker do
        pid_queue << connection.select_value('SELECT pg_backend_pid()')
        operation.call
      end
    end
    pids = Array.new(3) { Timeout.timeout(10) { pid_queue.pop } }
    expect(waiting_lock_count(pids)).to eq(3)
    release << true
    result(holder)
    threads.map { |thread| result(thread) }
  ensure
    release << true if release && holder&.alive?
  end

  def waiting_lock_count(pids)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    waiting = 0
    loop do
      waiting = connection.select_value(<<~SQL.squish).to_i
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'advisory' AND NOT granted
          AND pid IN (#{pids.join(',')})
          AND classid = CASE WHEN hashtext('#{lock_key}') < 0 THEN 4294967295 ELSE 0 END
          AND objid = (hashtext('#{lock_key}')::bigint & 4294967295)
          AND objsubid = 1
      SQL
      break if waiting == 3 || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
    waiting
  end

  # Commits a real rule write while the process tree is being loaded, so the
  # loaded content can be newer than the version read just before it.
  def with_commit_during_catalog_load
    committed = false
    allow(Souq::Schema::Catalog).to receive(:load).and_wrap_original do |original|
      unless committed
        committed = true
        outcome = result(worker { set_rule(cars, slot_a, mode: :enable) })
        raise outcome if outcome.is_a?(Exception)
      end
      original.call
    end
    yield
  ensure
    allow(Souq::Schema::Catalog).to receive(:load).and_call_original
  end
end
