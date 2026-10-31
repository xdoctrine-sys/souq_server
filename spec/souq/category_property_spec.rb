# frozen_string_literal: true

require 'rails_helper'
require_relative 'support/taxonomy'
require_relative 'support/taxonomy_cache'

RSpec.describe 'SOUQ category tree property' do # rubocop:disable RSpec/DescribeClass
  def expect_tree_property
    random = Random.new(202_612)
    account = Fabricate(:account)
    50.times do |index|
      parents = [nil, *Souq::Category.where('depth < 3').to_a]
      Souq::Categories::Create.call(account: account, parent: parents.sample(random: random),
                                    code: "property_#{index}", name_en: 'Category', name_ar: 'Category')
    end
    failures = []
    100.times do |step|
      before = Souq::Category.order(:id).pluck(:id, :parent_id, :ancestor_ids, :depth, :position, :lock_version)
      version = read_taxonomy_version
      logs = Souq::AuditLog.count
      rows = Souq::Category.order(:id).to_a
      begin
        if step % 5 == 0
          Souq::Categories::Create.call(account: account, parent: [nil, *rows].sample(random: random),
                                        code: "operation_#{step}", name_en: 'Category', name_ar: 'Category')
        else
          category = rows.sample(random: random)
          parent = step % 7 == 0 ? category : [nil, *rows].sample(random: random)
          Souq::Categories::Move.call(account: account, category: category, new_parent: parent, lock_version: category.lock_version)
        end
      rescue Souq::Categories::CycleError, Souq::Categories::DepthError => e
        failures << e.class
        expect(Souq::Category.order(:id).pluck(:id, :parent_id, :ancestor_ids, :depth, :position, :lock_version)).to eq(before), "seed=202612 step=#{step}"
        expect(read_taxonomy_version).to eq(version)
        expect(Souq::AuditLog.count).to eq(logs)
      end
      Souq::Category.connection.execute('SET CONSTRAINTS ALL IMMEDIATE')
      Souq::Category.connection.execute('SET CONSTRAINTS ALL DEFERRED')
      rows = Souq::Category.order(:id).to_a
      by_id = rows.index_by(&:id)
      rows.each do |row|
        ids = []
        parent_id = row.parent_id
        while parent_id
          expect(ids).to_not include(parent_id), "cycle seed=202612 step=#{step}"
          ids.unshift(parent_id)
          parent_id = by_id.fetch(parent_id).parent_id
        end
        expect(row.ancestor_ids).to eq(ids), "ancestors seed=202612 step=#{step} id=#{row.id}"
        expect(row.depth).to eq(ids.size), "depth seed=202612 step=#{step} id=#{row.id}"
        expect(row.depth).to be <= 3
      end
      rows.group_by(&:parent_id).each_value do |siblings|
        expect(siblings.map(&:position).sort).to eq((0...siblings.size).to_a), "positions seed=202612 step=#{step}"
      end
    end
    expect(failures).to include(Souq::Categories::CycleError, Souq::Categories::DepthError)
  end

  it 'keeps independently recalculated ancestry and sibling positions after 100 operations (seed 202612)' do
    expect_tree_property
  end
end
