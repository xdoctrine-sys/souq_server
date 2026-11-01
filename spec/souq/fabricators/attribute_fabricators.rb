# frozen_string_literal: true

Fabricator(:souq_attribute_definition, class_name: 'Souq::AttributeDefinition') do
  code { sequence(:souq_attribute_definition_code) { |number| "attribute_#{number}" } }
  name_en 'Test attribute'
  name_ar 'Test attribute'
  data_type 'single_option'
end

Fabricator(:souq_attribute_option, class_name: 'Souq::AttributeOption') do
  definition { Fabricate(:souq_attribute_definition) }
  code { sequence(:souq_attribute_option_code) { |number| "option_#{number}" } }
  name_en 'Test option'
  name_ar 'Test option'
end

Fabricator(:souq_category_attribute, class_name: 'Souq::CategoryAttribute') do
  category { Fabricate(:souq_category) }
  definition { Fabricate(:souq_attribute_definition) }
  mode 'enable'
end
