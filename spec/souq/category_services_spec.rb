# frozen_string_literal: true

require 'rails_helper'
require_relative 'support/taxonomy'
require_relative 'support/taxonomy_cache'

RSpec.describe 'SOUQ category services' do # rubocop:disable RSpec/DescribeClass
  let!(:account) { Fabricate(:account) }
  let!(:root) { Fabricate(:souq_category, position: 0) }
  let!(:other) { Fabricate(:souq_category, position: 1) }
  let!(:child) { Fabricate(:souq_category, parent: root) }
  let!(:leaf) { Fabricate(:souq_category, parent: child) }

  before do
    write_taxonomy_version(5)
    Souq::TaxonomyCache.reset!
  end

  def tree
    Souq::Category.order(:id).pluck(:id, :parent_id, :ancestor_ids, :depth, :position, :lock_version)
  end

  def move(category = root, parent = other, position: nil, lock_version: category.reload.lock_version)
    Souq::Categories::Move.call(account: account, category: category, new_parent: parent, position: position, lock_version: lock_version)
  end

  def create(parent: nil, position: nil, **attributes)
    Souq::Categories::Create.call(account: account, parent: parent, position: position,
                                  code: Fabricate.sequence(:category_service_code) { |n| "t2_#{n}" },
                                  name_en: 'Category', name_ar: 'Category', **attributes)
  end

  def reorder(ids, parent: nil)
    Souq::Categories::Reorder.call(account: account, parent: parent, ordered_ids: ids)
  end

  def expect_unchanged
    before = [tree, read_taxonomy_version, Souq::AuditLog.count]
    yield
    expect([tree, read_taxonomy_version, Souq::AuditLog.count]).to eq(before)
  end

  it 'rejects cycles below self and grandchild without writes' do
    [root, leaf].each do |parent|
      expect_unchanged { expect { move(root, parent) }.to raise_error(Souq::Categories::CycleError) }
    end
  end

  it 'rejects depth four and accepts exactly depth three' do
    deepest = create(parent: leaf).category
    expect(deepest.depth).to eq(3)
    expect_unchanged { expect { create(parent: deepest) }.to raise_error(Souq::Categories::DepthError) }
    expect_unchanged { expect { move(root, child) }.to raise_error(Souq::Categories::CycleError) }
    expect_unchanged { expect { move(other, deepest) }.to raise_error(Souq::Categories::DepthError) }
    expect_unchanged { expect { move(root, other) }.to raise_error(Souq::Categories::DepthError) }
  end

  it 'rewrites all descendants in one statement and moves back to roots' do
    statements = []
    counter = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { move }
    expect(statements.grep(/UPDATE souq_categories SET.*ancestor_ids/i).size).to eq(1)
    expect(root.reload.ancestor_ids).to eq([other.id])
    expect(child.reload.ancestor_ids).to eq([other.id, root.id])
    expect(leaf.reload.ancestor_ids).to eq([other.id, root.id, child.id])
    expect(leaf.depth).to eq(3)
    move(root, nil)
    expect(root.reload.ancestor_ids).to eq([])
    expect(child.reload.ancestor_ids).to eq([root.id])
    expect(leaf.reload.ancestor_ids).to eq([root.id, child.id])
  end

  it 'increments locks on the node, descendants and shifted sibling only' do
    before = Souq::Category.pluck(:id, :lock_version).to_h
    move
    [root, child, leaf, other].each { |row| expect(row.reload.lock_version).to eq(before.fetch(row.id) + 1) }
  end

  it 'rejects stale locks without writes' do
    expect_unchanged { expect { move(lock_version: -1) }.to raise_error(Souq::Categories::ConflictError) }
  end

  it 'inserts at beginning, middle and end with contiguous positions' do
    [0, 1, nil].each do |position|
      category = create(position: position).category
      siblings = Souq::Category.where(parent_id: nil).order(:position).to_a
      expect(siblings.map(&:position)).to eq((0...siblings.size).to_a)
      expect(siblings[position || -1].id).to eq(category.id)
    end
  end

  it 'reorders within one parent without rewriting descendants or unchanged siblings' do
    third = create.category
    locks = Souq::Category.pluck(:id, :lock_version).to_h
    result = move(third, nil, position: 1)
    expect(result).to be_changed
    expect(Souq::Category.where(parent_id: nil).order(:position).pluck(:id)).to eq([root.id, third.id, other.id])
    [root, child, leaf].each { |row| expect(row.reload.lock_version).to eq(locks.fetch(row.id)) }
    [third, other].each { |row| expect(row.reload.lock_version).to eq(locks.fetch(row.id) + 1) }
    expect(Souq::AuditLog.last.recorded_changes.fetch('descendants_rewritten')).to eq(0)
  end

  it 'returns unchanged for the same parent and position' do
    snapshot = Souq::TaxonomyCache.snapshot
    expect_unchanged { expect(move(root, nil, position: 0)).to_not be_changed }
    expect(Souq::Current.taxonomy_snapshot).to equal(snapshot)
  end

  it 'rejects every malformed reorder and accepts an identical list as unchanged' do
    [[root.id], [root.id, other.id, child.id], [root.id, root.id], [other.id, child.id]].each do |ids|
      expect_unchanged { expect { reorder(ids) }.to raise_error(Souq::Categories::ConflictError) }
    end
    expect_unchanged { expect(reorder([root.id, other.id])).to_not be_changed }
  end

  it 'reorders in one update and increments only changed locks' do
    locks = Souq::Category.pluck(:id, :lock_version).to_h
    statements = []
    counter = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { reorder([other.id, root.id]) }
    expect(statements.grep(/UPDATE souq_categories/).size).to eq(1)
    expect(Souq::Category.where(parent_id: nil).order(:position).pluck(:id)).to eq([other.id, root.id])
    [root, other].each { |row| expect(row.reload.lock_version).to eq(locks.fetch(row.id) + 1) }
    [child, leaf].each { |row| expect(row.reload.lock_version).to eq(locks.fetch(row.id)) }
  end

  it 'increments the version exactly once and audits each changing operation' do
    [-> { create }, -> { move }, -> { reorder(Souq::Category.where(parent_id: nil).order(:position).pluck(:id).reverse) }].each do |operation|
      before = read_taxonomy_version
      expect { operation.call }.to change(Souq::AuditLog, :count).by(1)
      expect(read_taxonomy_version).to eq(before + 1)
      expect(Souq::AuditLog.last.account_id).to eq(account.id)
      expect(Souq::AuditLog.last.recorded_changes.keys).to contain_exactly('before', 'after', 'descendants_rewritten')
    end
  end

  it 'rolls back subtree, siblings, version and audit on a late audit error' do
    allow(Souq::AuditLog).to receive(:create!).and_raise('forced late audit error')
    expect_unchanged { expect { move }.to raise_error(RuntimeError, 'forced late audit error') }
  end

  it 'initializes a missing singleton at bootstrap plus one' do
    clear_taxonomy_version
    create
    expect(read_taxonomy_version).to eq(Souq::TaxonomyCache::BOOTSTRAP_VERSION + 1)
  end

  it 'requires an actor and rejects caller supplied ancestry' do
    expect { Souq::Categories::Create.call(account: nil) }.to raise_error(Souq::Categories::ValidationError)
    expect { create(ancestor_ids: [root.id]) }.to raise_error(Souq::Categories::ValidationError)
    expect { move(root, 'unknown_category') }.to raise_error(Souq::Categories::NotFoundError)
  end

  it 'uses model validation errors with field details and preserves listable defaults' do
    expect { create(hashtag: 'invalid-tag') }.to raise_error(Souq::Categories::ValidationError) { |error| expect(error.details).to have_key(:hashtag) }
    expect(create.category.listable).to eq(Souq::Category.column_defaults.fetch('listable'))
    expect(create(listable: false).category.listable).to be(false)
  end
end
