# frozen_string_literal: true

require 'rails_helper'
require_relative 'support/attributes'

RSpec.describe Souq::AttributeDefinition do
  let(:connection) { ActiveRecord::Base.connection }
  let(:definition) { Fabricate(:souq_attribute_definition) }
  let(:option) { Fabricate(:souq_attribute_option, definition:) }
  let(:rule) { Fabricate(:souq_category_attribute, definition:) }

  def execute_bound(sql, *values)
    connection.execute(ActiveRecord::Base.sanitize_sql_array([sql, *values]))
  end

  def expect_rejected(sql, *values, error: ActiveRecord::StatementInvalid)
    expect do
      connection.transaction(requires_new: true) { execute_bound(sql, *values) }
    end.to raise_error(error)
  end

  it 'rejects malformed definition codes in direct SQL' do
    expect_rejected('UPDATE souq_attribute_definitions SET code = ? WHERE id = ?', 'bad-code', definition.id, error: ActiveRecord::StatementInvalid)
    expect(definition.reload.code).to_not eq('bad-code')
  end

  it 'rejects malformed option codes in direct SQL' do
    expect_rejected('UPDATE souq_attribute_options SET code = ? WHERE id = ?', 'bad-code', option.id)
    expect(option.reload.code).to_not eq('bad-code')
  end

  it 'rejects self dependencies in direct SQL' do
    expect_rejected('UPDATE souq_attribute_definitions SET depends_on_id = id WHERE id = ?', definition.id)
    expect(definition.reload.depends_on_id).to be_nil
  end

  it 'rejects inverted numeric bounds in direct SQL' do
    expect_rejected('UPDATE souq_attribute_definitions SET min_value = 2, max_value = 1 WHERE id = ?', definition.id)
    expect(definition.reload.min_value).to be_nil
  end

  it 'rejects nonpositive max_length in direct SQL' do
    [0, -1].each { |length| expect_rejected('UPDATE souq_attribute_definitions SET max_length = ? WHERE id = ?', length, definition.id) }
    expect(definition.reload.max_length).to be_nil
  end

  it 'rejects unknown data_type values in direct SQL' do
    expect_rejected('UPDATE souq_attribute_definitions SET data_type = 99 WHERE id = ?', definition.id)
    expect(definition.reload.data_type).to eq('single_option')
  end

  it 'rejects unknown filter_widget values in direct SQL' do
    expect_rejected('UPDATE souq_attribute_definitions SET filter_widget = 99 WHERE id = ?', definition.id)
    expect(definition.reload.filter_widget).to be_nil
  end

  it 'rejects unknown mode values in direct SQL' do
    expect_rejected('UPDATE souq_category_attributes SET mode = 99 WHERE id = ?', rule.id)
    expect(rule.reload.mode).to eq('enable')
  end

  it 'rejects nonobject config in direct SQL' do
    expect_rejected('UPDATE souq_category_attributes SET config = CAST(? AS jsonb) WHERE id = ?', '[]', rule.id)
    expect(rule.reload.config).to eq({})
  end

  it 'rejects nonobject condition in direct SQL' do
    expect_rejected('UPDATE souq_category_attributes SET condition = CAST(? AS jsonb) WHERE id = ?', '[]', rule.id)
    expect(rule.reload.condition).to be_nil
  end

  it 'rejects duplicate definition codes in direct SQL' do
    other = Fabricate(:souq_attribute_definition)
    expect_rejected('UPDATE souq_attribute_definitions SET code = ? WHERE id = ?', definition.code, other.id, error: ActiveRecord::RecordNotUnique)
  end

  it 'rejects duplicate definition and option code pairs in direct SQL' do
    other = Fabricate(:souq_attribute_option, definition:)
    expect_rejected('UPDATE souq_attribute_options SET code = ? WHERE id = ?', option.code, other.id, error: ActiveRecord::RecordNotUnique)
  end

  it 'rejects duplicate category and definition pairs in direct SQL' do
    other = Fabricate(:souq_category_attribute, category: rule.category)
    expect_rejected('UPDATE souq_category_attributes SET definition_id = ? WHERE id = ?', definition.id, other.id, error: ActiveRecord::RecordNotUnique)
  end

  it 'restricts deleting a definition used by a category rule' do
    rule
    expect_rejected('DELETE FROM souq_attribute_definitions WHERE id = ?', definition.id, error: ActiveRecord::InvalidForeignKey)
    expect(rule.reload).to be_persisted
  end

  it 'restricts deleting a definition used by a dependent definition' do
    child = Fabricate(:souq_attribute_definition, depends_on: definition)
    expect_rejected('DELETE FROM souq_attribute_definitions WHERE id = ?', definition.id, error: ActiveRecord::InvalidForeignKey)
    expect(child.reload.depends_on_id).to eq(definition.id)
  end

  it 'cascades deleting a definition to its options' do
    id = option.id
    execute_bound('DELETE FROM souq_attribute_definitions WHERE id = ?', definition.id)
    expect(Souq::AttributeOption.exists?(id)).to be(false)
  end

  it 'cascades deleting a category to its rules' do
    id = rule.id
    execute_bound('DELETE FROM souq_categories WHERE id = ?', rule.category_id)
    expect(Souq::CategoryAttribute.exists?(id)).to be(false)
  end

  it 'restricts deleting a parent option with dependent children' do
    child_definition = Fabricate(:souq_attribute_definition, depends_on: definition)
    child = Fabricate(:souq_attribute_option, definition: child_definition, parent_option: option)
    expect_rejected('DELETE FROM souq_attribute_options WHERE id = ?', option.id, error: ActiveRecord::InvalidForeignKey)
    expect(child.reload.parent_option_id).to eq(option.id)
  end

  it 'enforces every foreign key in direct SQL' do
    expect_rejected('UPDATE souq_attribute_definitions SET depends_on_id = -1 WHERE id = ?', definition.id, error: ActiveRecord::InvalidForeignKey)
    expect_rejected('UPDATE souq_attribute_options SET definition_id = -1 WHERE id = ?', option.id, error: ActiveRecord::InvalidForeignKey)
    expect_rejected('UPDATE souq_attribute_options SET parent_option_id = -1 WHERE id = ?', option.id, error: ActiveRecord::InvalidForeignKey)
    expect_rejected('UPDATE souq_category_attributes SET category_id = -1 WHERE id = ?', rule.id, error: ActiveRecord::InvalidForeignKey)
    expect_rejected('UPDATE souq_category_attributes SET definition_id = -1 WHERE id = ?', rule.id, error: ActiveRecord::InvalidForeignKey)
  end

  it 'indexes each foreign key and the requested ordering pairs' do
    indexes = connection.indexes('souq_attribute_definitions')
    expect(indexes.map(&:columns)).to include(['depends_on_id'])
    indexes = connection.indexes('souq_attribute_options')
    expect(indexes.map(&:columns)).to include(%w(definition_id code), %w(definition_id position), ['parent_option_id'])
    indexes = connection.indexes('souq_category_attributes')
    expect(indexes.map(&:columns)).to include(%w(category_id definition_id), ['definition_id'])
  end
end
