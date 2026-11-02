# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'
require_relative '../support/attributes'
require_relative '../support/schema_reference'

# The effective schema of a category is computed root first and cached in the
# taxonomy snapshot (SOUQ_CATEGORIES_DESIGN.md section 3.4). These examples
# exercise the documented reference example and every decision of the prompt's
# section 1. A resolution problem is data (a machine-readable issue), never an
# exception raised out of the snapshot.
RSpec.describe Souq::Schema::Resolve do
  include SouqSchemaReference

  let(:version) { 11 }

  before do
    install_reference_schema
    write_taxonomy_version(version)
    Souq::TaxonomyCache.reset!
  end

  def schema(code)
    Souq::TaxonomyCache.schema(code)
  end

  def codes(code)
    schema(code).codes
  end

  def issue_codes(code)
    schema(code).issues.pluck(:code)
  end

  describe 'the section 3.4 reference example' do
    it 'resolves vehicles to transaction_type and year' do
      expect(codes('vehicles')).to eq(%w(transaction_type year))
      expect(schema('vehicles').attribute('transaction_type')[:required]).to be(true)
      expect(schema('vehicles')).to_not be_invalid
    end

    it 'resolves cars as the inherited attributes, in position order, plus the car-specific ones' do
      expect(codes('cars')).to eq(%w(transaction_type year brand model mileage_km vehicle_condition deposit min_rental_days))
      expect(schema('cars')).to_not be_invalid
    end

    it 'keeps spare_parts limited to the sale transaction type and removes year' do
      expect(codes('spare_parts')).to eq(%w(transaction_type))
      expect(schema('spare_parts')).to_not be_invalid
      entry = schema('spare_parts').attribute('transaction_type')
      expect(entry[:options].pluck(:code)).to eq(%w(sale))
    end

    it 'resolves real_estate with its own attributes' do
      expect(codes('real_estate')).to eq(%w(transaction_type area_m2 furnished))
      expect(schema('real_estate')).to_not be_invalid
    end

    it 'exposes the condition as data so a client can show or hide the field' do
      expect(schema('cars').attribute('deposit')[:condition]).to eq({ attribute: 'transaction_type', in: ['rent'] })
      expect(schema('cars').attribute('mileage_km')[:condition]).to eq({ attribute: 'transaction_type', in: ['sale'] })
      expect(schema('vehicles').attribute('year')[:condition]).to be_nil
    end

    it 'returns every active option of a dependent attribute with its parent option' do
      entry = schema('cars').attribute('model')
      options = entry[:options].to_h { |option| [option[:code], option[:parent_option]] }
      expect(options).to eq({ 'corolla' => 'toyota', 'patrol' => 'nissan' })
      expect(entry[:depends_on]).to eq('brand')
    end

    it 'freezes the resolved attributes so a caller cannot mutate the cache' do
      expect(schema('cars').attributes).to be_frozen
      expect(schema('cars').attribute('brand')).to be_frozen
      expect(schema('cars').attribute('model')[:options]).to be_frozen
    end
  end

  describe 'inheritance rules' do
    it 'reactivates an attribute disabled higher up with an enable in a descendant' do
      root = reference_category('react_root', 'Root', 'جذر')
      child = reference_category('react_child', 'Child', 'ابن', parent: root)
      grandchild = reference_category('react_grandchild', 'Grandchild', 'حفيد', parent: child)
      definition = reference_definition('react_attr', 0, 'single_option')
      reference_rule(root, definition, mode: :enable)
      reference_rule(child, definition, mode: :disable)
      reference_rule(grandchild, definition, mode: :enable)
      Souq::TaxonomyCache.reset!

      expect(codes('react_root')).to eq(%w(react_attr))
      expect(codes('react_child')).to eq([])
      expect(codes('react_grandchild')).to eq(%w(react_attr))
    end

    it 'merges only the fields an override carries and keeps the inherited condition otherwise' do
      root = reference_category('merge_root', 'Root', 'جذر')
      child = reference_category('merge_child', 'Child', 'ابن', parent: root)
      pilot = reference_definition('merge_pilot', 0, 'single_option')
      reference_option(pilot, 'on')
      reference_option(pilot, 'off')
      definition = reference_definition('merge_attr', 1, 'single_option')
      reference_rule(root, pilot, mode: :enable)
      reference_rule(root, definition, mode: :enable, required: true, condition: { 'attribute' => 'merge_pilot', 'in' => ['on'] })
      reference_rule(child, definition, mode: :override, required: false)
      Souq::TaxonomyCache.reset!

      entry = schema('merge_child').attribute('merge_attr')
      expect(entry[:required]).to be(false)
      expect(entry[:condition]).to eq({ attribute: 'merge_pilot', in: ['on'] })
    end
  end

  describe 'invalid resolutions are data, not exceptions' do
    def with_rules(parent_code:, child_code: nil)
      root = reference_category(parent_code, parent_code, parent_code)
      child = child_code ? reference_category(child_code, child_code, child_code, parent: root) : nil
      [root, child]
    end

    it 'reports an enable of an attribute already inherited' do
      root, child = with_rules(parent_code: 'dup_root', child_code: 'dup_child')
      definition = reference_definition('dup_attr', 0, 'single_option')
      reference_rule(root, definition, mode: :enable)
      reference_rule(child, definition, mode: :enable)
      Souq::TaxonomyCache.reset!

      expect(issue_codes('dup_child')).to include('enable_already_inherited')
      expect(schema('dup_child').issues.first.category).to eq('dup_child')
      expect(schema('dup_child').issues.first.attribute).to eq('dup_attr')
    end

    it 'reports an override of an attribute that is not inherited' do
      root, = with_rules(parent_code: 'orph_root')
      definition = reference_definition('orph_attr', 0, 'single_option')
      reference_rule(root, definition, mode: :override)
      Souq::TaxonomyCache.reset!

      expect(issue_codes('orph_root')).to include('override_without_inherited')
    end

    it 'reports an override that widens the inherited options' do
      root, child = with_rules(parent_code: 'wide_root', child_code: 'wide_child')
      definition = reference_definition('wide_attr', 0, 'single_option')
      reference_option(definition, 'aa')
      reference_option(definition, 'bb')
      reference_rule(root, definition, mode: :enable, config: { 'allowed_option_codes' => ['aa'] })
      reference_rule(child, definition, mode: :override, config: { 'allowed_option_codes' => %w(aa bb) })
      Souq::TaxonomyCache.reset!

      expect(issue_codes('wide_child')).to include('override_widens_options')
    end

    it 'reports an override that widens the inherited bounds' do
      root, child = with_rules(parent_code: 'bound_root', child_code: 'bound_child')
      definition = reference_definition('bound_attr', 0, 'integer')
      reference_rule(root, definition, mode: :enable, config: { 'min_value' => 10, 'max_value' => 20 })
      reference_rule(child, definition, mode: :override, config: { 'max_value' => 25 })
      Souq::TaxonomyCache.reset!

      expect(issue_codes('bound_child')).to include('override_widens_bounds')
    end

    it 'reports a missing dependency when the pilot is disabled' do
      root, child = with_rules(parent_code: 'dep_root', child_code: 'dep_child')
      brand = reference_definition('dep_brand', 0, 'single_option')
      model = reference_definition('dep_model', 1, 'single_option', depends_on: brand)
      reference_option(brand, 'brand_x')
      reference_option(model, 'model_x', parent_option: Souq::AttributeOption.find_by(code: 'brand_x'))
      reference_rule(root, brand, mode: :enable)
      reference_rule(root, model, mode: :enable)
      reference_rule(child, brand, mode: :disable)
      Souq::TaxonomyCache.reset!

      expect(issue_codes('dep_child')).to include('missing_dependency')
    end

    it 'reports a condition whose pilot is absent, chained, or references an unknown option' do
      root = reference_category('cond_root', 'Root', 'جذر')
      pilot = reference_definition('cond_pilot', 0, 'single_option')
      reference_option(pilot, 'pp')
      absent = reference_definition('cond_absent', 1, 'single_option')
      unknown = reference_definition('cond_unknown', 2, 'single_option')
      chained = reference_definition('cond_chained', 3, 'single_option')
      reference_rule(root, pilot, mode: :enable)
      reference_rule(root, absent, mode: :enable, condition: { 'attribute' => 'cond_missing', 'in' => ['pp'] })
      reference_rule(root, unknown, mode: :enable, condition: { 'attribute' => 'cond_pilot', 'in' => ['zz'] })
      # `cond_absent` carries a condition, so conditioning another attribute on
      # it is a chain.
      reference_rule(root, chained, mode: :enable, condition: { 'attribute' => 'cond_absent', 'in' => ['pp'] })
      Souq::TaxonomyCache.reset!

      result = schema('cond_root')
      by_attribute = result.issues.group_by(&:attribute).transform_values { |issues| issues.pluck(:code) }
      expect(by_attribute['cond_absent']).to include('condition_missing_attribute')
      expect(by_attribute['cond_unknown']).to include('condition_unknown_option')
      expect(by_attribute['cond_chained']).to include('condition_chained')
    end

    it 'warns instead of failing when a restriction makes the condition never true' do
      root = reference_category('warn_root', 'Root', 'جذر')
      pilot = reference_definition('warn_pilot', 0, 'single_option')
      reference_option(pilot, 'on')
      reference_option(pilot, 'off')
      restricted = reference_definition('warn_restricted', 1, 'single_option')
      reference_option(restricted, 'rr')
      reference_rule(root, pilot, mode: :enable, config: { 'allowed_option_codes' => ['on'] })
      reference_rule(root, restricted, mode: :enable, condition: { 'attribute' => 'warn_pilot', 'in' => ['off'] })
      Souq::TaxonomyCache.reset!

      result = schema('warn_root')
      expect(result.issues).to be_empty
      expect(result.warnings.pluck(:code)).to include('condition_never_true')
    end
  end

  describe 'bounds and length restrictions' do
    def with_pair(parent_code, child_code)
      root = reference_category(parent_code, parent_code, parent_code)
      child = reference_category(child_code, child_code, child_code, parent: root)
      [root, child]
    end

    it 'rejects a null bound instead of silently dropping the inherited restriction' do
      root, child = with_pair('nullbound_root', 'nullbound_child')
      definition = reference_definition('nullbound_attr', 0, 'integer')
      reference_rule(root, definition, mode: :enable, config: { 'min_value' => 10, 'max_value' => 20 })
      reference_rule(child, definition, mode: :override, config: { 'min_value' => nil })
      Souq::TaxonomyCache.reset!

      expect(issue_codes('nullbound_child')).to include('invalid_bound')
    end

    it 'rejects a malformed bound' do
      root, child = with_pair('badbound_root', 'badbound_child')
      definition = reference_definition('badbound_attr', 0, 'decimal')
      reference_rule(root, definition, mode: :enable, config: { 'max_value' => 20 })
      reference_rule(child, definition, mode: :override, config: { 'max_value' => 'abc' })
      Souq::TaxonomyCache.reset!

      expect(issue_codes('badbound_child')).to include('invalid_bound')
    end

    it 'rejects a non-finite bound instead of letting it replace the inherited one' do
      %w(NaN Infinity -Infinity).each_with_index do |raw, index|
        root, child = with_pair("nonfinite#{index}_root", "nonfinite#{index}_child")
        definition = reference_definition("nonfinite#{index}_attr", 0, 'decimal')
        reference_rule(root, definition, mode: :enable, config: { 'min_value' => 10, 'max_value' => 20 })
        reference_rule(child, definition, mode: :override, config: { 'max_value' => raw })
        Souq::TaxonomyCache.reset!

        result = schema("nonfinite#{index}_child")
        expect(result.issues.pluck(:code)).to include('invalid_bound')
        # The inherited maximum is kept: the malformed override never applies.
        expect(result.attribute("nonfinite#{index}_attr")[:max]).to eq(BigDecimal(20))
      end
    end

    it 'rejects a bound on a non-numeric attribute' do
      root = reference_category('textbound_root', 'Root', 'جذر')
      definition = reference_definition('textbound_attr', 0, 'text')
      reference_rule(root, definition, mode: :enable, config: { 'min_value' => 5 })
      Souq::TaxonomyCache.reset!

      expect(issue_codes('textbound_root')).to include('invalid_bound')
    end

    it 'rejects an override that lowers the inherited minimum' do
      root, child = with_pair('lowmin_root', 'lowmin_child')
      definition = reference_definition('lowmin_attr', 0, 'integer')
      reference_rule(root, definition, mode: :enable, config: { 'min_value' => 10 })
      reference_rule(child, definition, mode: :override, config: { 'min_value' => 5 })
      Souq::TaxonomyCache.reset!

      expect(issue_codes('lowmin_child')).to include('override_widens_bounds')
    end

    it 'keeps an override that only tightens the inherited bounds' do
      root, child = with_pair('tight_root', 'tight_child')
      definition = reference_definition('tight_attr', 0, 'integer')
      reference_rule(root, definition, mode: :enable, config: { 'min_value' => 10, 'max_value' => 20 })
      reference_rule(child, definition, mode: :override, config: { 'min_value' => 12, 'max_value' => 18 })
      Souq::TaxonomyCache.reset!

      result = schema('tight_child')
      expect(result).to_not be_invalid
      expect(result.attribute('tight_attr')[:min]).to eq(BigDecimal(12))
      expect(result.attribute('tight_attr')[:max]).to eq(BigDecimal(18))
    end

    it 'fixes max_length from the enable config' do
      root = reference_category('len_root', 'Root', 'جذر')
      definition = reference_definition('len_attr', 0, 'text')
      reference_rule(root, definition, mode: :enable, config: { 'max_length' => 5 })
      Souq::TaxonomyCache.reset!

      expect(schema('len_root').attribute('len_attr')[:max_length]).to eq(5)
    end

    it 'fixes max_length from the definition default when the enable carries none' do
      root = reference_category('lendef_root', 'Root', 'جذر')
      definition = reference_definition('lendef_attr', 0, 'text', max_length: 7)
      reference_rule(root, definition, mode: :enable)
      Souq::TaxonomyCache.reset!

      expect(schema('lendef_root').attribute('lendef_attr')[:max_length]).to eq(7)
    end

    it 'accepts an override that lowers max_length' do
      root, child = with_pair('lenlow_root', 'lenlow_child')
      definition = reference_definition('lenlow_attr', 0, 'text')
      reference_rule(root, definition, mode: :enable, config: { 'max_length' => 100 })
      reference_rule(child, definition, mode: :override, config: { 'max_length' => 20 })
      Souq::TaxonomyCache.reset!

      result = schema('lenlow_child')
      expect(result).to_not be_invalid
      expect(result.attribute('lenlow_attr')[:max_length]).to eq(20)
    end

    it 'rejects an override that raises max_length' do
      root, child = with_pair('lenraise_root', 'lenraise_child')
      definition = reference_definition('lenraise_attr', 0, 'text')
      reference_rule(root, definition, mode: :enable, config: { 'max_length' => 20 })
      reference_rule(child, definition, mode: :override, config: { 'max_length' => 50 })
      Souq::TaxonomyCache.reset!

      expect(issue_codes('lenraise_child')).to include('override_widens_bounds')
    end

    it 'rejects max_length on a non-text attribute' do
      root = reference_category('lenint_root', 'Root', 'جذر')
      definition = reference_definition('lenint_attr', 0, 'integer')
      reference_rule(root, definition, mode: :enable, config: { 'max_length' => 5 })
      Souq::TaxonomyCache.reset!

      expect(issue_codes('lenint_root')).to include('invalid_bound')
    end

    it 'applies the default text limit when neither the config nor the definition sets one' do
      root = reference_category('deflen_root', 'Root', 'جذر')
      definition = reference_definition('deflen_attr', 0, 'text')
      reference_rule(root, definition, mode: :enable)
      Souq::TaxonomyCache.reset!

      expect(schema('deflen_root').attribute('deflen_attr')[:max_length]).to eq(Souq::Schema::Typing::DEFAULT_MAX_LENGTH)
    end

    it 'rejects an override that widens the default text limit to 2000' do
      root, child = with_pair('deflenraise_root', 'deflenraise_child')
      definition = reference_definition('deflenraise_attr', 0, 'text')
      reference_rule(root, definition, mode: :enable)
      reference_rule(child, definition, mode: :override, config: { 'max_length' => 2000 })
      Souq::TaxonomyCache.reset!

      result = schema('deflenraise_child')
      expect(result.issues.pluck(:code)).to include('override_widens_bounds')
      # The effective limit stays at the default, it is never raised.
      expect(result.attribute('deflenraise_attr')[:max_length]).to eq(Souq::Schema::Typing::DEFAULT_MAX_LENGTH)
    end

    it 'accepts an override that tightens the default text limit' do
      root, child = with_pair('deflentight_root', 'deflentight_child')
      definition = reference_definition('deflentight_attr', 0, 'text')
      reference_rule(root, definition, mode: :enable)
      reference_rule(child, definition, mode: :override, config: { 'max_length' => 400 })
      Souq::TaxonomyCache.reset!

      result = schema('deflentight_child')
      expect(result).to_not be_invalid
      expect(result.attribute('deflentight_attr')[:max_length]).to eq(400)
    end
  end

  it 'ignores inactive definitions and their rules' do
    root = reference_category('hidden_root', 'Root', 'جذر')
    definition = Fabricate(:souq_attribute_definition,
                           code: 'hidden_attr', name_en: 'hidden', name_ar: 'hidden',
                           data_type: 'single_option', position: 0, active: false)
    reference_rule(root, definition, mode: :enable)
    Souq::TaxonomyCache.reset!

    expect(codes('hidden_root')).to eq([])
    expect(definition).to be_persisted
  end

  describe 'cache consistency' do
    it 'precomputes the same attributes and issues as a fresh Resolve from the database' do
      snapshot = Souq::TaxonomyCache.snapshot
      catalog = Souq::Schema::Catalog.load
      rows = Souq::Category.order(:id).pluck(:id, :code, :ancestor_ids)
      categories = described_class.categories_from_rows(rows)

      %w(vehicles cars spare_parts real_estate).each do |code|
        fresh = described_class.for_category(catalog: catalog, categories: categories, category: categories.fetch(code))
        expect(snapshot.schema(code).attributes).to eq(fresh.attributes)
        expect(snapshot.schema(code).issues.pluck(:code)).to eq(fresh.issues.pluck(:code))
      end
    end

    it 'keeps the snapshot loadable when one category resolves to an invalid schema' do
      root = reference_category('mixed_root', 'Root', 'جذر')
      child = reference_category('mixed_child', 'Child', 'ابن', parent: root)
      definition = reference_definition('mixed_attr', 0, 'single_option')
      reference_rule(root, definition, mode: :enable)
      reference_rule(child, definition, mode: :enable)
      Souq::TaxonomyCache.reset!

      snapshot = Souq::TaxonomyCache.snapshot
      expect(snapshot.schema('mixed_child').issues).to_not be_empty
      expect(snapshot.schema('cars')).to_not be_invalid
      expect(snapshot.category('mixed_root')[:code]).to eq('mixed_root')
    end
  end
end
