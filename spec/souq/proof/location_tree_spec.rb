# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'

RSpec.describe 'SOUQ location tree at real commit', if: ENV['SOUQ_COMMIT_PROOF'] == '1', use_transactional_tests: false do # rubocop:disable RSpec/DescribeClass
  let(:connection) { Souq::Location.connection }
  let(:created_ids) { [] }
  let!(:roles_before) { UserRole.order(:id).pluck(:id, :name) }
  let!(:root) { create_location }
  let!(:other) { create_location }
  let!(:city) { create_location(parent: root, kind: 'city') }
  let!(:area) { create_location(parent: city, kind: 'area') }

  after do
    Souq::Location.where(id: created_ids).order(depth: :desc).each(&:destroy!)
    expect(UserRole.order(:id).pluck(:id, :name)).to eq(roles_before) # rubocop:disable RSpec/ExpectInHook
  end

  def create_location(**attributes)
    Fabricate(:souq_location, **attributes).tap { |location| created_ids << location.id }
  end

  def reject_sql(sql)
    expect { connection.transaction { connection.execute(sql) } }.to raise_error(ActiveRecord::StatementInvalid, /PG::CheckViolation/)
  end

  it 'refuses an ancestor_ids-only update' do
    reject_sql("UPDATE souq_locations SET ancestor_ids = ARRAY[#{other.id}]::bigint[] WHERE id = #{city.id}")
    expect(city.reload.ancestor_ids).to eq([root.id])
  end

  it 'refuses a parent_id-only update' do
    reject_sql("UPDATE souq_locations SET parent_id = #{other.id} WHERE id = #{city.id}")
    expect(city.reload.parent_id).to eq(root.id)
  end

  it 'refuses depth greater than two' do
    reject_sql("UPDATE souq_locations SET depth = 3 WHERE id = #{area.id}")
    expect(area.reload.depth).to eq(2)
  end

  it 'refuses a city root even when its ancestry is coherent' do
    reject_sql("UPDATE souq_locations SET parent_id = NULL, ancestor_ids = '{}'::bigint[], depth = 0 WHERE id = #{city.id}")
    expect(city.reload.parent_id).to eq(root.id)
  end

  it 'refuses a region with a parent' do
    reject_sql("UPDATE souq_locations SET parent_id = #{other.id}, ancestor_ids = ARRAY[#{other.id}]::bigint[], depth = 1 WHERE id = #{root.id}")
    expect(root.reload.parent_id).to be_nil
  end

  it 'refuses a coherent node move without rewriting its children at commit' do
    reached_end = false
    expect do
      connection.transaction do
        connection.execute("UPDATE souq_locations SET parent_id = #{other.id}, ancestor_ids = ARRAY[#{other.id}]::bigint[] WHERE id = #{city.id}")
        reached_end = true
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /SOUQ location children/)
    expect(reached_end).to be(true)
    expect(city.reload.parent_id).to eq(root.id)
  end

  it 'accepts a coherent complete subtree rewrite in one statement' do
    connection.transaction do
      connection.execute(<<~SQL.squish)
        UPDATE souq_locations SET
          parent_id = CASE WHEN id = #{city.id} THEN #{other.id} ELSE parent_id END,
          ancestor_ids = ARRAY[#{other.id}]::bigint[] || ancestor_ids[2:cardinality(ancestor_ids)]
        WHERE id = #{city.id} OR ancestor_ids @> ARRAY[#{city.id}]::bigint[]
      SQL
    end
    expect(city.reload.ancestor_ids).to eq([other.id])
    expect(area.reload.ancestor_ids).to eq([other.id, city.id])
    expect(area.depth).to eq(2)
  end

  it 'reads final rows after compensated updates' do
    connection.transaction do
      connection.execute("UPDATE souq_locations SET parent_id = #{other.id}, ancestor_ids = ARRAY[#{other.id}]::bigint[] WHERE id = #{city.id}")
      connection.execute("UPDATE souq_locations SET parent_id = #{root.id}, ancestor_ids = ARRAY[#{root.id}]::bigint[] WHERE id = #{city.id}")
    end
    expect(city.reload.parent_id).to eq(root.id)
  end

  it 'refuses self-parent, self-ancestor and direct parent deletion' do
    reject_sql("UPDATE souq_locations SET parent_id = id WHERE id = #{city.id}")
    reject_sql("UPDATE souq_locations SET ancestor_ids = ARRAY[#{city.id}]::bigint[] WHERE id = #{city.id}")
    expect { connection.transaction { connection.execute("DELETE FROM souq_locations WHERE id = #{root.id}") } }
      .to raise_error(ActiveRecord::InvalidForeignKey)
    expect(root.reload).to be_persisted
  end
end
