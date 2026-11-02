# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'
require_relative '../support/attributes'
require_relative '../support/schema_reference'

# The rule write services (design section 3.4, prompt section 3). One
# transaction takes the very same advisory lock as the category tree, replays
# the resolution of the changed category and its descendants, and only then
# bumps souq_settings.taxonomy_version and writes the audit row.
RSpec.describe 'SOUQ schema rule services' do # rubocop:disable RSpec/DescribeClass
  include SouqSchemaReference

  let(:version) { 5 }
  let!(:account) { Fabricate(:account) }
  let!(:root) { reference_category('rules_root', 'Root', 'جذر') }
  let!(:child) { reference_category('rules_child', 'Child', 'ابن', parent: root) }
  let!(:definition) { reference_definition('rules_attr', 0, 'single_option') }

  before do
    reference_option(definition, 'aa')
    reference_option(definition, 'bb')
    write_taxonomy_version(version)
    Souq::TaxonomyCache.reset!
  end

  def set_rule(category, target, **options)
    Souq::Schema::Rules::Set.call(account: account, category: category, definition: target, **options)
  end

  def remove_rule(category, target)
    Souq::Schema::Rules::Remove.call(account: account, category: category, definition: target)
  end

  def stored_rule(category = root)
    Souq::CategoryAttribute.find_by(category_id: category.id, definition_id: definition.id)
  end

  describe Souq::Schema::Rules::Set do
    it 'creates the rule, bumps the version once and records a create action' do
      result = set_rule(root, definition, mode: :enable, required: true)

      expect(result).to have_attributes(changed?: true, category_code: 'rules_root', definition_code: 'rules_attr')
      expect(result.taxonomy_version).to eq(version + 1)
      expect(stored_rule).to have_attributes(mode: 'enable', required: true)
      expect(Souq::AuditLog.last).to have_attributes(action: 'create', target_type: 'Souq::CategoryAttribute', account_id: account.id)
    end

    it 'reports an unchanged rule without bumping the version or writing an audit row' do
      set_rule(root, definition, mode: :enable, required: true)

      expect { set_rule(root, definition, mode: :enable, required: true) }
        .to not_change { read_taxonomy_version }.and not_change(Souq::AuditLog, :count)
    end

    it 'updates a rule and records the before and after snapshots' do
      set_rule(root, definition, mode: :enable, required: true)

      result = set_rule(root, definition, mode: :enable, required: false)

      expect(result).to have_attributes(changed?: true, taxonomy_version: version + 2)
      expect(Souq::AuditLog.last.recorded_changes.fetch('before')).to include('required' => true)
      expect(Souq::AuditLog.last.recorded_changes.fetch('after')).to include('required' => false)
    end

    it 'rejects an actor that is not a persisted account' do
      expect { described_class.call(account: nil, category: root, definition: definition, mode: :enable) }
        .to raise_error(Souq::Schema::ValidationError)
    end

    it 'raises NotFoundError for an unknown category or definition' do
      expect { set_rule('ghost', definition, mode: :enable) }.to raise_error(Souq::Schema::NotFoundError)
      expect { set_rule(root, 'ghost', mode: :enable) }.to raise_error(Souq::Schema::NotFoundError)
    end

    it 'rolls the rule, the version and the audit row back when the rule itself cannot resolve' do
      expect do
        set_rule(root, definition, mode: :enable, condition: { 'attribute' => 'ghost', 'in' => ['aa'] })
      end.to raise_error(Souq::Schema::RuleError)

      expect(stored_rule).to be_nil
      expect(read_taxonomy_version).to eq(version)
      expect(Souq::AuditLog.count).to eq(0)
    end

    it 'rolls everything back when a descendant can no longer resolve' do
      set_rule(root, definition, mode: :enable, config: { 'allowed_option_codes' => ['aa'] })
      set_rule(child, definition, mode: :override, config: { 'allowed_option_codes' => ['aa'] })
      baseline = [read_taxonomy_version, Souq::AuditLog.count, stored_rule.config, stored_rule(child).config]

      expect do
        set_rule(root, definition, mode: :enable, config: { 'allowed_option_codes' => ['bb'] })
      end.to raise_error(Souq::Schema::RuleError)

      expect([read_taxonomy_version, Souq::AuditLog.count, stored_rule.config, stored_rule(child).config]).to eq(baseline)
    end

    it 'returns the resolver warnings of the changed category, with category and attribute' do
      pilot = reference_definition('rules_pilot', 1, 'single_option')
      reference_option(pilot, 'on')
      reference_option(pilot, 'off')
      dependent = reference_definition('rules_dependent', 2, 'single_option')
      reference_option(dependent, 'dd')

      set_rule(root, pilot, mode: :enable, config: { 'allowed_option_codes' => ['on'] })
      result = set_rule(root, dependent, mode: :enable, condition: { 'attribute' => 'rules_pilot', 'in' => ['off'] })

      expect(result.changed?).to be(true)
      warning = result.warnings.find { |entry| entry.code == 'condition_never_true' }
      expect(warning).to be_present
      expect(warning.category).to eq('rules_root')
      expect(warning.attribute).to eq('rules_dependent')
    end

    it 'returns the resolver warnings of a descendant in the result of the write' do
      pilot = reference_definition('rules_dpilot', 1, 'single_option')
      reference_option(pilot, 'on')
      reference_option(pilot, 'off')
      dependent = reference_definition('rules_ddependent', 2, 'single_option')
      reference_option(dependent, 'dd')

      set_rule(root, pilot, mode: :enable)
      set_rule(child, dependent, mode: :enable, condition: { 'attribute' => 'rules_dpilot', 'in' => ['off'] })

      result = set_rule(root, pilot, mode: :enable, config: { 'allowed_option_codes' => ['on'] })

      warning = result.warnings.find { |entry| entry.code == 'condition_never_true' }
      expect(warning).to be_present
      expect(warning.category).to eq('rules_child')
      expect(warning.attribute).to eq('rules_ddependent')
    end

    it 'returns no warnings for an unchanged write' do
      set_rule(root, definition, mode: :enable)

      result = set_rule(root, definition, mode: :enable)

      expect(result.changed?).to be(false)
      expect(result.warnings).to eq([])
    end

    it 'rejects a null bound and rolls the descendant write back' do
      number = reference_definition('rules_number', 1, 'integer')
      set_rule(root, number, mode: :enable, config: { 'min_value' => 10, 'max_value' => 20 })

      expect do
        set_rule(child, number, mode: :override, config: { 'min_value' => nil })
      end.to raise_error(Souq::Schema::RuleError)

      expect(Souq::CategoryAttribute.find_by(category_id: child.id, definition_id: number.id)).to be_nil
    end

    it 'accepts max_length as a rule config key and stores it' do
      text = reference_definition('rules_text', 1, 'text')

      set_rule(root, text, mode: :enable, config: { 'max_length' => 12 })

      expect(Souq::CategoryAttribute.find_by(category_id: root.id, definition_id: text.id).config).to eq('max_length' => 12)
    end

    it 'rejects an override that raises max_length and rolls it back' do
      text = reference_definition('rules_text', 2, 'text')
      set_rule(root, text, mode: :enable, config: { 'max_length' => 20 })

      expect do
        set_rule(child, text, mode: :override, config: { 'max_length' => 50 })
      end.to raise_error(Souq::Schema::RuleError)

      expect(Souq::CategoryAttribute.find_by(category_id: child.id, definition_id: text.id)).to be_nil
    end
  end

  describe Souq::Schema::Rules::Remove do
    it 'removes the rule, bumps the version and records a deactivate action' do
      set_rule(root, definition, mode: :enable)

      result = remove_rule(root, definition)

      expect(result.changed?).to be(true)
      expect(result.taxonomy_version).to eq(version + 2)
      expect(stored_rule).to be_nil
      expect(Souq::AuditLog.last).to have_attributes(action: 'deactivate', target_type: 'Souq::CategoryAttribute')
    end

    it 'reports a missing rule as unchanged' do
      expect { remove_rule(root, definition) }.to not_change { read_taxonomy_version }.and not_change(Souq::AuditLog, :count)
    end

    it 'refuses to remove a rule that a descendant override still needs' do
      set_rule(root, definition, mode: :enable)
      set_rule(child, definition, mode: :override)

      expect { remove_rule(root, definition) }.to raise_error(Souq::Schema::RuleError)
      expect(stored_rule).to be_present
    end
  end
end
