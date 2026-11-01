# frozen_string_literal: true

require 'rails_helper'
require_relative 'support/attribute_fields'

RSpec.describe Souq::AttributeOption do
  it_behaves_like 'SOUQ attribute fields', :souq_attribute_option

  it 'requires a definition' do
    record = Fabricate.build(:souq_attribute_option, definition: nil)
    expect(record).to_not be_valid
    expect(record.errors[:definition]).to be_present
  end

  it 'supports single and multi option definitions only' do
    %w(single_option multi_option).each do |type|
      definition = Fabricate(:souq_attribute_definition, data_type: type)
      expect(Fabricate.build(:souq_attribute_option, definition: definition)).to be_valid
    end
    definition = Fabricate(:souq_attribute_definition, data_type: 'integer')
    record = Fabricate.build(:souq_attribute_option, definition: definition)
    expect(record).to_not be_valid
    expect(record.errors[:definition]).to include('must support options')
  end

  it 'requires a code unique within its definition' do
    option = Fabricate(:souq_attribute_option)
    record = Fabricate.build(:souq_attribute_option, definition: option.definition, code: option.code)
    expect(record).to_not be_valid
    expect(record.errors[:code]).to be_present
    expect(Fabricate.build(:souq_attribute_option, code: option.code)).to be_valid
  end

  it 'requires a parent option for dependent definitions' do
    definition = Fabricate(:souq_attribute_definition, depends_on: Fabricate(:souq_attribute_definition))
    record = Fabricate.build(:souq_attribute_option, definition: definition)
    expect(record).to_not be_valid
    expect(record.errors[:parent_option]).to be_present
  end

  it 'accepts a parent option belonging to the dependency' do
    parent = Fabricate(:souq_attribute_option)
    definition = Fabricate(:souq_attribute_definition, depends_on: parent.definition)
    expect(Fabricate.build(:souq_attribute_option, definition: definition, parent_option: parent)).to be_valid
  end

  it 'rejects a dependent option pointing to the wrong definition' do
    definition = Fabricate(:souq_attribute_definition, depends_on: Fabricate(:souq_attribute_definition))
    record = Fabricate.build(:souq_attribute_option, definition: definition, parent_option: Fabricate(:souq_attribute_option))
    expect(record).to_not be_valid
    expect(record.errors[:parent_option]).to include('must belong to the depends_on definition')
  end

  it 'forbids parent options without a dependency' do
    record = Fabricate.build(:souq_attribute_option)
    expect(record).to be_valid
    record.parent_option = Fabricate(:souq_attribute_option)
    expect(record).to_not be_valid
    expect(record.errors[:parent_option]).to include('must be empty without a dependency')
  end
end
