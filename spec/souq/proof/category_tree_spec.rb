# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'

# This contract verifies PostgreSQL constraints at an actual commit.
RSpec.describe 'SOUQ category tree at real commit', if: ENV['SOUQ_COMMIT_PROOF'] == '1', use_transactional_tests: false do # rubocop:disable RSpec/DescribeClass
  let(:connection) { Souq::Category.connection }
  let(:created_ids) { [] }
  let!(:roles_before) { UserRole.order(:id).pluck(:id, :name) }
  let!(:root) { create_category }
  let!(:other) { create_category }
  let!(:child) { create_category(parent: root) }
  let!(:leaf) { create_category(parent: child) }

  after do
    Souq::Category.where(id: created_ids).order(depth: :desc).each(&:destroy!)
    expect(UserRole.order(:id).pluck(:id, :name)).to eq(roles_before) # rubocop:disable RSpec/ExpectInHook
  end

  def create_category(**attributes)
    Fabricate(:souq_category, **attributes).tap { |category| created_ids << category.id }
  end

  def reject_sql(sql)
    expect { connection.transaction { connection.execute(sql) } }.to raise_error(ActiveRecord::StatementInvalid, /PG::CheckViolation/)
  end

  it 'refuses an ancestor_ids-only update' do
    reject_sql("UPDATE souq_categories SET ancestor_ids = ARRAY[#{other.id}]::bigint[] WHERE id = #{child.id}")
    expect(child.reload.ancestor_ids).to eq([root.id])
  end

  it 'refuses a depth-only update' do
    reject_sql("UPDATE souq_categories SET depth = 2 WHERE id = #{child.id}")
    expect(child.reload.depth).to eq(1)
  end

  it 'refuses a parent_id-only update' do
    reject_sql("UPDATE souq_categories SET parent_id = #{other.id} WHERE id = #{child.id}")
    expect(child.reload.parent_id).to eq(root.id)
  end

  it 'refuses moving a node without rewriting its unchanged children at commit' do
    reached_end = false
    expect do
      connection.transaction do
        connection.execute("UPDATE souq_categories SET parent_id = #{other.id}, ancestor_ids = ARRAY[#{other.id}]::bigint[], depth = 1 WHERE id = #{root.id}")
        reached_end = true
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /SOUQ category children/)
    expect(reached_end).to be(true)
    expect(root.reload.parent_id).to be_nil
  end

  it 'refuses including the category in its own ancestors' do
    reject_sql("UPDATE souq_categories SET ancestor_ids = ARRAY[#{child.id}]::bigint[] WHERE id = #{child.id}")
    expect(child.reload.ancestor_ids).to eq([root.id])
  end

  it 'refuses parent_id equal to id' do
    reject_sql("UPDATE souq_categories SET parent_id = id WHERE id = #{child.id}")
    expect(child.reload.parent_id).to eq(root.id)
  end

  it 'accepts a coherent complete subtree rewrite in one SQL statement' do
    connection.transaction do
      connection.execute(<<~SQL.squish)
        UPDATE souq_categories SET
          parent_id = CASE WHEN id = #{root.id} THEN #{other.id} ELSE parent_id END,
          ancestor_ids = ARRAY[#{other.id}]::bigint[] || ancestor_ids,
          depth = depth + 1
        WHERE id = #{root.id} OR ancestor_ids @> ARRAY[#{root.id}]::bigint[]
      SQL
    end
    expect(root.reload.ancestor_ids).to eq([other.id])
    expect(child.reload.ancestor_ids).to eq([other.id, root.id])
    expect(leaf.reload.ancestor_ids).to eq([other.id, root.id, child.id])
    expect(leaf.depth).to eq(3)
  end

  it 'checks final rows after multiple updates, not intermediate trigger images' do
    connection.transaction do
      connection.execute("UPDATE souq_categories SET parent_id = #{other.id}, ancestor_ids = ARRAY[#{other.id}]::bigint[] WHERE id = #{child.id}")
      connection.execute("UPDATE souq_categories SET parent_id = #{root.id}, ancestor_ids = ARRAY[#{root.id}]::bigint[] WHERE id = #{child.id}")
    end
    expect(child.reload.parent_id).to eq(root.id)
  end

  it 'checks ancestry on an unrelated-column update' do
    definition = connection.select_value("SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgname = 'souq_categories_tree_check'")
    expect(definition).to include('AFTER INSERT OR UPDATE ON', 'DEFERRABLE INITIALLY DEFERRED')
    connection.transaction { connection.execute("UPDATE souq_categories SET position = 2 WHERE id = #{child.id}") }
    expect(child.reload.position).to eq(2)
  end

  it 'refuses deleting a parent through direct SQL' do
    expect { connection.transaction { connection.execute("DELETE FROM souq_categories WHERE id = #{root.id}") } }
      .to raise_error(ActiveRecord::InvalidForeignKey)
    expect(root.reload).to be_persisted
  end
end
