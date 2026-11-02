# frozen_string_literal: true

require 'rails_helper'
require_relative 'support/taxonomy'
require_relative 'support/taxonomy_cache'
require_relative 'support/attributes'
require_relative 'support/schema_reference'

# The validator reads only the in-memory snapshot (design section 3.6): it
# never issues a SQL query of its own. These examples exercise every error code
# of MESSAGES and the normalization of a valid payload.
RSpec.describe Souq::ListingAttributesValidator do
  include SouqSchemaReference

  let(:version) { 11 }

  before do
    install_reference_schema
    install_validator_extras
    write_taxonomy_version(version)
    Souq::TaxonomyCache.reset!
  end

  def validate(values, category: 'cars')
    described_class.call(category: category, values: values)
  end

  def error_codes(result, code)
    result.error_codes.fetch(code, [])
  end

  # A dedicated category carrying every scalar type, a multi_option, a
  # restricted option list and an inactive option, so each error code can be
  # reached without touching the reference taxonomy.
  def install_validator_extras
    root = reference_category('val', 'Val', 'فحص')
    seats = extra_definition('seats', 0, 'integer')
    note = Fabricate(:souq_attribute_definition,
                     code: 'note', name_en: 'note', name_ar: 'note',
                     data_type: 'text', max_length: 5, position: 1)
    warranty = extra_definition('warranty', 2, 'date')
    features = extra_definition('features', 3, 'multi_option')
    size = extra_definition('size', 4, 'single_option')
    colour = extra_definition('colour', 5, 'single_option')

    reference_option(features, 'ac')
    reference_option(features, 'abs')
    Fabricate(:souq_attribute_option, definition: features, code: 'gps', name_en: 'gps', name_ar: 'gps', active: false)
    %w(sm md lg).each { |code| reference_option(size, code) }
    reference_option(colour, 'red')
    Fabricate(:souq_attribute_option, definition: colour, code: 'green', name_en: 'green', name_ar: 'green', active: false)

    reference_rule(root, seats, mode: :enable, config: { 'min_value' => 1, 'max_value' => 9 })
    reference_rule(root, note, mode: :enable)
    reference_rule(root, warranty, mode: :enable)
    reference_rule(root, features, mode: :enable)
    reference_rule(root, size, mode: :enable, config: { 'allowed_option_codes' => %w(sm md) })
    reference_rule(root, colour, mode: :enable)
  end

  def extra_definition(code, position, data_type)
    Fabricate(:souq_attribute_definition, code: code, name_en: code, name_ar: code,
                                          data_type: data_type, position: position)
  end

  describe 'a valid sale listing' do
    let(:values) do
      { 'transaction_type' => 'sale', 'year' => 2019, 'brand' => 'toyota',
        'model' => 'corolla', 'mileage_km' => 50_000, 'vehicle_condition' => 'used' }
    end

    it 'accepts it and returns the normalized values in schema order' do
      result = validate(values)

      expect(result).to be_valid
      expect(result.values).to eq(
        'transaction_type' => 'sale', 'year' => 2019, 'brand' => 'toyota',
        'model' => 'corolla', 'mileage_km' => 50_000, 'vehicle_condition' => 'used'
      )
    end

    it 'normalizes a decimal to a string without ever using a float' do
      result = validate({ 'transaction_type' => 'rent', 'brand' => 'toyota', 'deposit' => '1500.00', 'min_rental_days' => 3 })

      expect(result).to be_valid
      expect(result.values.fetch('deposit')).to eq('1500')
      expect(result.values.fetch('deposit')).to be_a(String)
    end

    it 'accepts a Souq::Category object as well as a code' do
      category = Souq::Category.find_by(code: 'cars')

      expect(validate(values, category: category)).to be_valid
    end
  end

  describe 'category-wide failures' do
    it 'reports an unknown category under the reserved key' do
      result = validate({}, category: 'nowhere')

      expect(result).to_not be_valid
      expect(error_codes(result, described_class::CATEGORY_KEY)).to eq(%w(unknown_category))
    end

    it 'reports a category whose effective schema is invalid' do
      root = reference_category('broken_root', 'Root', 'جذر')
      child = reference_category('broken_child', 'Child', 'ابن', parent: root)
      definition = reference_definition('broken_attr', 0, 'single_option')
      reference_rule(root, definition, mode: :enable)
      reference_rule(child, definition, mode: :enable)
      Souq::TaxonomyCache.reset!

      result = validate({}, category: 'broken_child')

      expect(error_codes(result, described_class::CATEGORY_KEY)).to eq(%w(invalid_schema))
    end

    it 'reports values that are not an object' do
      result = validate('not a hash')

      expect(error_codes(result, described_class::CATEGORY_KEY)).to eq(%w(invalid_values))
    end

    it 'reports a key that is not part of the schema' do
      result = validate({ 'transaction_type' => 'sale', 'brand' => 'toyota', 'bogus' => 1 })

      expect(error_codes(result, 'bogus')).to eq(%w(unknown_attribute))
    end
  end

  describe 'required and conditional attributes' do
    it 'reports a required attribute that is missing' do
      result = validate({ 'transaction_type' => 'sale' })

      expect(error_codes(result, 'brand')).to eq(%w(required))
    end

    it 'does not require an attribute whose condition is false' do
      result = validate({ 'transaction_type' => 'sale', 'brand' => 'toyota', 'model' => 'corolla' })

      expect(result).to be_valid
    end

    it 'refuses a value whose condition is false' do
      result = validate({ 'transaction_type' => 'sale', 'brand' => 'toyota', 'model' => 'corolla', 'deposit' => '10' })

      expect(error_codes(result, 'deposit')).to eq(%w(not_allowed_for_condition))
    end
  end

  describe 'option typing' do
    it 'reports an option that does not exist at all' do
      expect(error_codes(validate({ 'colour' => 'purple' }, category: 'val'), 'colour')).to eq(%w(unknown_option))
    end

    it 'reports an option that exists but is inactive' do
      expect(error_codes(validate({ 'colour' => 'green' }, category: 'val'), 'colour')).to eq(%w(inactive_option))
    end

    it 'reports an option outside the allowed list of the category' do
      expect(error_codes(validate({ 'size' => 'lg' }, category: 'val'), 'size')).to eq(%w(not_allowed_option))
    end

    it 'reports a repeated option in a multi_option' do
      expect(error_codes(validate({ 'features' => %w(ac ac) }, category: 'val'), 'features')).to eq(%w(duplicate_option))
    end

    it 'refuses a value that is not of the expected shape' do
      expect(error_codes(validate({ 'size' => 3 }, category: 'val'), 'size')).to eq(%w(invalid_type))
      expect(error_codes(validate({ 'features' => 'ac' }, category: 'val'), 'features')).to eq(%w(invalid_type))
    end
  end

  describe 'scalar typing' do
    it 'reports an integer out of bounds and a wrong type' do
      expect(error_codes(validate({ 'seats' => 0 }, category: 'val'), 'seats')).to eq(%w(out_of_bounds))
      expect(error_codes(validate({ 'seats' => 'x' }, category: 'val'), 'seats')).to eq(%w(invalid_type))
    end

    it 'reports text that is too long or carries control characters' do
      expect(error_codes(validate({ 'note' => 'abcdef' }, category: 'val'), 'note')).to eq(%w(too_long))
      expect(error_codes(validate({ 'note' => "ab\u0000c" }, category: 'val'), 'note')).to eq(%w(invalid_text))
    end

    it 'squishes accepted text' do
      result = validate({ 'note' => '  a  b ' }, category: 'val')

      expect(result.values.fetch('note')).to eq('a b')
    end

    it 'reports a malformed date differently from a wrong type' do
      expect(error_codes(validate({ 'warranty' => '2019-13-40' }, category: 'val'), 'warranty')).to eq(%w(invalid_date))
      expect(error_codes(validate({ 'warranty' => 123 }, category: 'val'), 'warranty')).to eq(%w(invalid_type))
    end
  end

  describe 'dependencies' do
    it 'reports a missing dependency when the pilot is absent' do
      result = validate({ 'transaction_type' => 'sale', 'brand' => nil, 'model' => 'corolla' })

      expect(error_codes(result, 'model')).to eq(%w(dependency_not_satisfied))
    end

    it 'reports an option that does not belong to the selected pilot option' do
      result = validate({ 'transaction_type' => 'sale', 'brand' => 'toyota', 'model' => 'patrol' })

      expect(error_codes(result, 'model')).to eq(%w(parent_option_mismatch))
    end
  end
end
