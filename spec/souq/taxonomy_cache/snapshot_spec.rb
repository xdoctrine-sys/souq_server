# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'

RSpec.describe Souq::TaxonomyCache::Snapshot do
  let!(:root) { Fabricate(:souq_category, position: 0) }
  let!(:other) { Fabricate(:souq_category, position: 1) }
  let!(:second) { Fabricate(:souq_category, parent: root, position: 1) }
  let!(:first) { Fabricate(:souq_category, parent: root, position: 0) }
  let!(:child) { Fabricate(:souq_category, parent: first) }
  let!(:leaf) { Fabricate(:souq_category, parent: child) }

  before do
    write_taxonomy_version(5)
    Souq::TaxonomyCache.reset!
  end

  def expect_snapshot_lookups(snapshot)
    expect(snapshot.category(root.code)).to equal(snapshot.category_by_id(root.id))
    expect(snapshot.ancestors(leaf.code).pluck(:id)).to eq([root.id, first.id, child.id])
    expect(snapshot.children(root.code).pluck(:id)).to eq([first.id, second.id])
    expect(snapshot.descendants(root.code).pluck(:id)).to eq([first.id, child.id, leaf.id, second.id])
    expect(snapshot.roots.pluck(:id)).to eq([root.id, other.id])
    expect(snapshot.category('unknown')).to be_nil
    expect(snapshot.category_by_id(-1)).to be_nil
    expect(snapshot.children('unknown')).to eq([])
    expect(snapshot.ancestors('unknown')).to eq([])
    expect(snapshot.descendants(leaf.code)).to eq([])
  end

  def expect_snapshot_frozen(snapshot)
    expect { snapshot.category(root.code)[:path] << 'bad' }.to raise_error(FrozenError)
    expect { snapshot.category_by_id(root.id)[:position] = 9 }.to raise_error(FrozenError)
    [snapshot.roots, snapshot.ancestors(leaf.code), snapshot.children(root.code), snapshot.descendants(root.code)].each do |entries|
      expect { entries << {} }.to raise_error(FrozenError)
      expect { entries.first[:code].replace('bad') }.to raise_error(FrozenError)
    end
  end

  it 'offers deeply frozen id, code, ancestor, child, descendant and root lookups without queries' do
    snapshot = Souq::TaxonomyCache.snapshot
    queries = []
    counter = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      expect_snapshot_lookups(snapshot)
      expect_snapshot_frozen(snapshot)
    end
    expect(queries).to be_empty
  end

  it 'constructs a snapshot and moves a category without consulting Redis' do
    account = Fabricate(:account)
    allow(RedisConnection).to receive(:with).and_raise(Redis::CannotConnectError)
    allow(RedisConnection).to receive(:pool).and_raise(Redis::CannotConnectError)
    allow(RedisConnection).to receive(:new).and_raise(Redis::CannotConnectError)
    snapshot = Souq::TaxonomyCache.snapshot
    expect(snapshot.version).to eq(5)
    result = Souq::Categories::Move.call(account: account, category: other, new_parent: root, lock_version: other.lock_version)
    expect(result).to be_changed
    expect(other.reload.parent_id).to eq(root.id)
    expect(RedisConnection).to_not have_received(:with)
    expect(RedisConnection).to_not have_received(:pool)
    expect(RedisConnection).to_not have_received(:new)
  end

  it 'ignores an orphan Redis version key' do
    redis.set('souq:taxonomy:version', 1)
    expect(Souq::TaxonomyCache.snapshot.version).to eq(5)
    expect(Souq::TaxonomyCache.snapshot.category(leaf.code)[:path]).to eq([root.code, first.code, child.code, leaf.code])
    expect(redis.get('souq:taxonomy:version')).to eq('1')
  end
end
