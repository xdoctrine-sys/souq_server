# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'

RSpec.shared_examples 'SOUQ taxonomy fields' do |fabricator|
  subject(:record) { Fabricate(fabricator) }

  %w(name_en name_ar).each do |field|
    it "requires #{field}" do
      record.public_send("#{field}=", '')
      expect(record).to_not be_valid
      expect(record.errors[field]).to be_present
    end
  end

  ['A_code', 'x', 'a' * 65, 'bad-code', 'bad code'].each do |code|
    it "rejects the invalid code #{code.inspect}" do
      candidate = Fabricate.build(fabricator, code:)
      expect(candidate).to_not be_valid
      expect(candidate.errors[:code]).to be_present
    end
  end

  it 'accepts ASCII codes at both length limits' do
    expect(Fabricate.build(fabricator, code: 'ab')).to be_valid
    expect(Fabricate.build(fabricator, code: 'a' * 64)).to be_valid
  end

  it 'requires globally unique codes in its table' do
    candidate = Fabricate.build(fabricator, code: record.code)
    expect(candidate).to_not be_valid
    expect(candidate.errors[:code]).to be_present
  end

  it 'refuses to change a persisted code' do
    record.code = 'different_code'
    expect(record).to_not be_valid
    expect(record.errors[:code]).to include('is immutable')
  end

  it 'accepts nil and hexadecimal colors' do
    [nil, '#aAbBcC', '#123456'].each do |color|
      record.color = color
      expect(record).to be_valid
    end
  end

  it 'rejects malformed colors' do
    ['', 'red', '#123', '#GGHHII'].each do |color|
      record.color = color
      expect(record).to_not be_valid
      expect(record.errors[:color]).to be_present
    end
  end

  it 'requires a nonnegative integer position' do
    record.position = -1
    expect(record).to_not be_valid
    expect(record.errors[:position]).to be_present
  end

  it 'requires a boolean active flag' do
    record.active = nil
    expect(record).to_not be_valid
    expect(record.errors[:active]).to be_present
  end
end

RSpec.describe Souq::ApplicationRecord do
  describe Souq::Market do
    it_behaves_like 'SOUQ taxonomy fields', :souq_market
  end

  describe Souq::Category do
    let(:invalid_tags) { ['', '#cars', 'two words', '12345'] }
    let(:valid_tags) { [nil, 'cars', 'سيارات'] }

    it_behaves_like 'SOUQ taxonomy fields', :souq_category

    it 'initializes an ordered ancestry path through four levels' do
      nodes = [Fabricate(:souq_category)]
      3.times { nodes << Fabricate(:souq_category, parent: nodes.last) }
      expect(nodes.last.ancestor_ids).to eq(nodes.first(3).map(&:id))
      expect(nodes.last.depth).to eq(3)
      expect { Fabricate(:souq_category, parent: nodes.last) }.to raise_error(ActiveRecord::RecordInvalid, /Depth/)
    end

    it 'rejects an inconsistent ancestry, depth and cyclic parent' do
      category = Fabricate(:souq_category)
      category.parent = category
      category.ancestor_ids = [category.id]
      category.depth = 0
      expect(category).to_not be_valid
      expect(category.errors[:parent]).to be_present
      expect(category.errors[:depth]).to be_present
    end

    %w(hashtag hashtag_ar).each do |field|
      it "validates #{field} with the real Mastodon tag regex" do
        category = Fabricate(:souq_category)
        valid_tags.each do |value|
          category.public_send("#{field}=", value)
          expect(category).to be_valid
        end
        invalid_tags.each do |value|
          category.public_send("#{field}=", value)
          expect(category).to_not be_valid
          expect(category.errors[field]).to be_present
        end
      end
    end

    it 'requires a boolean listable flag' do
      category = Fabricate(:souq_category)
      category.listable = nil
      expect(category).to_not be_valid
      expect(category.errors[:listable]).to be_present
    end

    it 'refuses deletion of a category with children' do
      child = Fabricate(:souq_category, parent: Fabricate(:souq_category))
      expect { child.parent.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(described_class.exists?(child.parent_id)).to be(true)
    end
  end

  describe Souq::MarketCategory do
    it 'requires both associations' do
      record = described_class.new
      expect(record).to_not be_valid
      expect(record.errors[:market]).to be_present
      expect(record.errors[:category]).to be_present
    end

    it 'requires a unique market/category pair' do
      record = Fabricate(:souq_market_category)
      expect(described_class.new(market: record.market, category: record.category)).to_not be_valid
    end

    it 'requires position and featured values' do
      record = Fabricate(:souq_market_category)
      record.position = -1
      record.featured = nil
      expect(record).to_not be_valid
      expect(record.errors[:position]).to be_present
      expect(record.errors[:featured]).to be_present
    end
  end

  describe Souq::AuditLog do
    it 'stores a JSON change payload without replacing ActiveRecord Dirty' do
      record = Fabricate(:souq_audit_log)
      expect(record.reload.recorded_changes).to eq('name_en' => ['Old name', 'New name'])
      record.target_id += 1
      expect(record.changes).to include('target_id')
    end

    it 'validates action, account, target and payload' do
      record = described_class.new(action: 'unknown', target_id: 0, recorded_changes: nil)
      expect(record).to_not be_valid
      expect(record.errors.attribute_names).to include(:action, :account, :target_type, :target_id, :recorded_changes)
    end
  end

  describe Souq::Setting do
    it 'is a singleton with a positive taxonomy version' do
      expect(Fabricate(:souq_setting).id).to eq(1)
      expect(described_class.new).to_not be_valid
      expect(described_class.new(id: 2, taxonomy_version: 0)).to_not be_valid
    end
  end
end
