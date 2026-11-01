# frozen_string_literal: true

require 'rails_helper'
require_relative 'support/attribute_fields'

RSpec.describe Souq::AttributeDefinition do
  it_behaves_like 'SOUQ attribute fields', :souq_attribute_definition

  it 'requires a globally unique code' do
    record = Fabricate(:souq_attribute_definition)
    candidate = Fabricate.build(:souq_attribute_definition, code: record.code)
    expect(candidate).to_not be_valid
    expect(candidate.errors[:code]).to be_present
  end

  it 'uses prefixed enums without Rails method conflicts' do
    record = Fabricate.build(:souq_attribute_definition, filter_widget: 'select')
    expect(record.data_type_single_option?).to be(true)
    expect(record.filter_widget_select?).to be(true)
    described_class.data_types.each_key { |type| expect(Fabricate.build(:souq_attribute_definition, data_type: type)).to be_valid }
    described_class.filter_widgets.each_key { |widget| expect(Fabricate.build(:souq_attribute_definition, filter_widget: widget)).to be_valid }
  end

  it 'rejects unknown enum values and a missing data type' do
    record = Fabricate.build(:souq_attribute_definition, data_type: 'unknown', filter_widget: 'unknown')
    expect(record).to_not be_valid
    expect(record.errors.attribute_names).to include(:data_type, :filter_widget)
    record.data_type = nil
    expect(record).to_not be_valid
  end

  it 'requires a searchable boolean and defaults it to true' do
    record = Fabricate.build(:souq_attribute_definition)
    expect(record.searchable).to be(true)
    record.searchable = nil
    expect(record).to_not be_valid
    expect(record.errors[:searchable]).to be_present
  end

  it 'accepts numeric bounds for integer and decimal types' do
    %w(integer decimal).each do |type|
      record = Fabricate.build(:souq_attribute_definition, data_type: type, min_value: 1, max_value: 2)
      expect(record).to be_valid
      record.max_value = 0
      expect(record).to_not be_valid
      expect(record.errors[:max_value]).to be_present
    end
  end

  it 'rejects numeric bounds on other types' do
    record = Fabricate.build(:souq_attribute_definition, min_value: 1, max_value: 2)
    expect(record).to_not be_valid
    expect(record.errors.attribute_names).to include(:min_value, :max_value)
  end

  it 'allows only positive text lengths on text definitions' do
    record = Fabricate.build(:souq_attribute_definition, data_type: 'text', max_length: 10)
    expect(record).to be_valid
    record.max_length = 0
    expect(record).to_not be_valid
    expect(record.errors[:max_length]).to be_present
    record.assign_attributes(data_type: 'integer', max_length: 10)
    expect(record).to_not be_valid
  end

  it 'accepts a single_option dependency without its own dependency' do
    parent = Fabricate(:souq_attribute_definition)
    expect(Fabricate.build(:souq_attribute_definition, depends_on: parent)).to be_valid
  end

  it 'rejects a dependency on itself' do
    record = Fabricate(:souq_attribute_definition)
    record.depends_on = record
    expect(record).to_not be_valid
    expect(record.errors[:depends_on]).to be_present
  end

  it 'rejects dependencies on types other than single_option' do
    parent = Fabricate(:souq_attribute_definition, data_type: 'multi_option')
    record = Fabricate.build(:souq_attribute_definition, depends_on: parent)
    expect(record).to_not be_valid
    expect(record.errors[:depends_on]).to include('must be single_option')
  end

  it 'rejects a second level of dependency' do
    parent = Fabricate(:souq_attribute_definition, depends_on: Fabricate(:souq_attribute_definition))
    record = Fabricate.build(:souq_attribute_definition, depends_on: parent)
    expect(record).to_not be_valid
    expect(record.errors[:depends_on]).to include('must not depend on another definition')
  end

  it 'cannot introduce a dependency chain by editing the parent' do
    parent = Fabricate(:souq_attribute_definition)
    Fabricate(:souq_attribute_definition, depends_on: parent)
    parent.depends_on = Fabricate(:souq_attribute_definition)
    expect(parent).to_not be_valid
    expect(parent.errors[:depends_on]).to be_present
    parent.assign_attributes(depends_on: nil, data_type: 'integer')
    expect(parent).to_not be_valid
    expect(parent.errors[:data_type]).to be_present
  end

  it 'permits dependency edits before options exist' do
    record = Fabricate(:souq_attribute_definition)
    record.depends_on = Fabricate(:souq_attribute_definition)
    expect(record).to be_valid
    record.depends_on = nil
    expect(record).to be_valid
  end

  it 'cannot add, change or remove a dependency while options exist' do
    root = Fabricate(:souq_attribute_definition)
    root_option = Fabricate(:souq_attribute_option, definition: root)
    child = Fabricate(:souq_attribute_definition, depends_on: root)
    Fabricate(:souq_attribute_option, definition: child, parent_option: root_option)
    root.depends_on = Fabricate(:souq_attribute_definition)
    expect(root).to_not be_valid
    expect(root.errors[:depends_on_id]).to be_present
    [nil, Fabricate(:souq_attribute_definition)].each do |parent|
      child.depends_on = parent
      expect(child).to_not be_valid
      expect(child.errors[:depends_on_id]).to be_present
    end
  end

  it 'retains an option type while options exist' do
    record = Fabricate(:souq_attribute_definition)
    Fabricate(:souq_attribute_option, definition: record)
    record.data_type = 'multi_option'
    expect(record).to be_valid
    record.data_type = 'text'
    expect(record).to_not be_valid
    expect(record.errors[:data_type]).to be_present
  end
end
