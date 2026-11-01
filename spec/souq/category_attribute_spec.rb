# frozen_string_literal: true

require 'rails_helper'
require_relative 'support/attributes'

RSpec.describe Souq::CategoryAttribute do
  it 'requires category and definition associations' do
    record = described_class.new(mode: 'enable')
    expect(record).to_not be_valid
    expect(record.errors.attribute_names).to include(:category, :definition)
  end

  it 'requires a unique category and definition pair' do
    existing = Fabricate(:souq_category_attribute)
    record = Fabricate.build(:souq_category_attribute, category: existing.category, definition: existing.definition)
    expect(record).to_not be_valid
    expect(record.errors[:definition_id]).to be_present
  end

  it 'uses prefixed modes without Rails conflicts' do
    described_class.modes.each_key do |mode|
      record = Fabricate.build(:souq_category_attribute, mode:)
      expect(record).to be_valid
      expect(record.public_send("mode_#{mode}?")).to be(true)
    end
  end

  it 'rejects missing and unknown modes' do
    [nil, 'unknown'].each do |mode|
      record = Fabricate.build(:souq_category_attribute, mode:)
      expect(record).to_not be_valid
      expect(record.errors[:mode]).to be_present
    end
  end

  it 'accepts inherited and explicit required and position values' do
    expect(Fabricate.build(:souq_category_attribute, required: nil, position: nil)).to be_valid
    expect(Fabricate.build(:souq_category_attribute, required: false, position: 0)).to be_valid
    expect(Fabricate.build(:souq_category_attribute, required: true, position: 1)).to be_valid
    record = Fabricate.build(:souq_category_attribute, position: -1)
    expect(record).to_not be_valid
    expect(record.errors[:position]).to be_present
  end

  { required: false, position: 0, config: { 'min_value' => 1 }, condition: { 'attribute' => 'driver', 'in' => ['yes'] } }.each do |field, value|
    it "forbids #{field} overrides when disabled" do
      record = Fabricate.build(:souq_category_attribute, mode: 'disable')
      expect(record).to be_valid
      record.public_send("#{field}=", value)
      expect(record).to_not be_valid
      expect(record.errors[field]).to include('must be empty when disabled')
    end
  end

  it 'allows only the documented config keys' do
    config = { 'allowed_option_codes' => ['first'], 'min_value' => 1, 'max_value' => 2, 'default_value' => 1, 'filter_widget' => 'range' }
    record = Fabricate.build(:souq_category_attribute, config:)
    expect(record).to be_valid
    record.config['unexpected'] = true
    expect(record).to_not be_valid
    expect(record.errors[:config]).to include('contains unknown key unexpected')
  end

  [nil, [], 'text', 1].each do |config|
    it "rejects nonobject config #{config.inspect}" do
      record = Fabricate.build(:souq_category_attribute, config:)
      expect(record).to_not be_valid
      expect(record.errors[:config]).to include('must be an object')
    end
  end

  it 'requires allowed_option_codes to be a string list' do
    [[], ['first', 'second']].each do |codes|
      expect(Fabricate.build(:souq_category_attribute, config: { 'allowed_option_codes' => codes })).to be_valid
    end
    [nil, 'first', [1]].each do |codes|
      record = Fabricate.build(:souq_category_attribute, config: { 'allowed_option_codes' => codes })
      expect(record).to_not be_valid
      expect(record.errors[:config]).to be_present
    end
  end

  it 'requires a known config filter_widget' do
    Souq::AttributeDefinition.filter_widgets.each_key do |widget|
      expect(Fabricate.build(:souq_category_attribute, config: { 'filter_widget' => widget })).to be_valid
    end
    record = Fabricate.build(:souq_category_attribute, config: { 'filter_widget' => 'unknown' })
    expect(record).to_not be_valid
    expect(record.errors[:config]).to be_present
  end

  it 'accepts nil or the exact condition shape without resolving T6 semantics' do
    expect(Fabricate.build(:souq_category_attribute, condition: nil)).to be_valid
    expect(Fabricate.build(:souq_category_attribute, condition: { 'attribute' => 'not_resolved_yet', 'in' => ['unknown_option'] })).to be_valid
  end

  [[], {}, 'text', { 'attribute' => 'driver' }, { 'attribute' => 1, 'in' => ['yes'] }, { 'attribute' => 'driver', 'in' => [] },
   { 'attribute' => 'driver', 'in' => 'yes' }, { 'attribute' => 'driver', 'in' => [1] }, { 'attribute' => 'driver', 'in' => ['yes'], 'extra' => true }].each do |condition|
    it "rejects invalid condition #{condition.inspect}" do
      record = Fabricate.build(:souq_category_attribute, condition:)
      expect(record).to_not be_valid
      expect(record.errors[:condition]).to be_present
    end
  end

  it 'does not change the taxonomy version on direct writes or deletes' do
    setting = Souq::Setting.find_by(id: 1)
    before_version = setting&.taxonomy_version
    definition = Fabricate(:souq_attribute_definition)
    option = Fabricate(:souq_attribute_option, definition:)
    rule = Fabricate(:souq_category_attribute, definition:)
    rule.update!(required: true)
    rule.destroy!
    option.destroy!
    Souq::AttributeDefinition.find(definition.id).destroy!
    expect(Souq::Setting.find_by(id: 1)&.taxonomy_version).to eq(before_version)
  end

  it 'refuses deleting a freshly loaded definition with a rule in the database' do
    rule = Fabricate(:souq_category_attribute)
    definition = Souq::AttributeDefinition.find(rule.definition_id)
    expect(described_class.where(definition_id: definition.id).count).to eq(1)
    expect { definition.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(definition.errors.full_messages).to include('Cannot delete record because dependent category attributes exist')
    expect(rule.reload).to be_persisted
    expect(Souq::AttributeDefinition.exists?(definition.id)).to be(true)
  end
end
