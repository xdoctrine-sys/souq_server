# frozen_string_literal: true

# Builds the reference taxonomy of SOUQ_CATEGORIES_DESIGN.md section 3.4:
#
#   vehicles > cars / spare_parts, plus real_estate
#
# with `transaction_type`, `year`, `brand`, `model`, `mileage_km`,
# `vehicle_condition`, `deposit`, `min_rental_days`, `area_m2` and `furnished`.
#
# Rules are inserted directly, with the string keys the model expects, so the
# fixture never depends on the write service under test.
module SouqSchemaReference
  def reference_category(code, name_en, name_ar, parent: nil)
    Fabricate(:souq_category, code: code, name_en: name_en, name_ar: name_ar, parent: parent)
  end

  def reference_definition(code, position, data_type, depends_on: nil, max_length: nil)
    Fabricate(:souq_attribute_definition, code: code, name_en: code, name_ar: code,
                                          data_type: data_type, position: position,
                                          depends_on: depends_on, max_length: max_length)
  end

  def reference_option(definition, code, parent_option: nil)
    Fabricate(:souq_attribute_option, definition: definition, code: code, name_en: code,
                                      name_ar: code, parent_option: parent_option)
  end

  def reference_rule(category, definition, mode:, required: nil, config: {}, condition: nil)
    Fabricate(:souq_category_attribute, category: category, definition: definition, mode: mode.to_s,
                                        required: required, config: config, condition: condition)
  end

  def sale_condition
    { 'attribute' => 'transaction_type', 'in' => ['sale'] }
  end

  def rent_condition
    { 'attribute' => 'transaction_type', 'in' => ['rent'] }
  end

  def install_reference_schema
    vehicles = reference_category('vehicles', 'Vehicles', 'مركبات')
    cars = reference_category('cars', 'Cars', 'سيارات', parent: vehicles)
    spare_parts = reference_category('spare_parts', 'Spare parts', 'قطع غيار', parent: vehicles)
    real_estate = reference_category('real_estate', 'Real estate', 'عقارات')

    transaction_type = reference_definition('transaction_type', 0, 'single_option')
    year = reference_definition('year', 1, 'integer')
    brand = reference_definition('brand', 2, 'single_option')
    model = reference_definition('model', 3, 'single_option', depends_on: brand)
    mileage_km = reference_definition('mileage_km', 4, 'integer')
    vehicle_condition = reference_definition('vehicle_condition', 5, 'single_option')
    deposit = reference_definition('deposit', 6, 'decimal')
    min_rental_days = reference_definition('min_rental_days', 7, 'integer')
    area_m2 = reference_definition('area_m2', 8, 'decimal')
    furnished = reference_definition('furnished', 9, 'boolean')

    sale = reference_option(transaction_type, 'sale')
    rent = reference_option(transaction_type, 'rent')
    toyota = reference_option(brand, 'toyota')
    nissan = reference_option(brand, 'nissan')
    corolla = reference_option(model, 'corolla', parent_option: toyota)
    patrol = reference_option(model, 'patrol', parent_option: nissan)
    reference_option(vehicle_condition, 'new')
    reference_option(vehicle_condition, 'used')

    reference_rule(vehicles, transaction_type, mode: :enable, required: true)
    reference_rule(vehicles, year, mode: :enable)

    reference_rule(cars, brand, mode: :enable, required: true)
    reference_rule(cars, model, mode: :enable)
    reference_rule(cars, mileage_km, mode: :enable, condition: sale_condition)
    reference_rule(cars, vehicle_condition, mode: :enable, condition: sale_condition)
    reference_rule(cars, deposit, mode: :enable, condition: rent_condition)
    reference_rule(cars, min_rental_days, mode: :enable, condition: rent_condition)

    reference_rule(spare_parts, transaction_type, mode: :override, config: { 'allowed_option_codes' => ['sale'] })
    reference_rule(spare_parts, year, mode: :disable)

    reference_rule(real_estate, transaction_type, mode: :enable, required: true)
    reference_rule(real_estate, area_m2, mode: :enable)
    reference_rule(real_estate, furnished, mode: :enable, condition: rent_condition)

    {
      vehicles: vehicles, cars: cars, spare_parts: spare_parts, real_estate: real_estate,
      definitions: {
        transaction_type:, year:, brand:, model:, mileage_km:, vehicle_condition:,
        deposit:, min_rental_days:, area_m2:, furnished:
      },
      options: { sale:, rent:, toyota:, nissan:, corolla:, patrol: }
    }
  end
end
