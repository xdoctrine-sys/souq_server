# frozen_string_literal: true

Fabricator(:souq_market, class_name: 'Souq::Market') do
  code { sequence(:souq_market_code) { |number| "market_#{number}" } }
  name_en 'Test market'
  name_ar 'سوق'
end

Fabricator(:souq_category, class_name: 'Souq::Category') do
  code { sequence(:souq_category_code) { |number| "category_#{number}" } }
  name_en 'Test category'
  name_ar 'فئة'
end

Fabricator(:souq_market_category, class_name: 'Souq::MarketCategory') do
  market { Fabricate(:souq_market) }
  category { Fabricate(:souq_category) }
end

Fabricator(:souq_audit_log, class_name: 'Souq::AuditLog') do
  account { Fabricate(:account) }
  action 'create'
  target_type 'Souq::Category'
  target_id { Fabricate(:souq_category).id }
  recorded_changes { { 'name_en' => ['Old name', 'New name'] } }
end

Fabricator(:souq_setting, class_name: 'Souq::Setting') do
  id 1
  taxonomy_version 1
end

Fabricator(:souq_location, class_name: 'Souq::Location') do
  code { sequence(:souq_location_code) { |number| "location_#{number}" } }
  name_en 'Test location'
  name_ar 'منطقة'
  kind 'region'
end

Fabricator(:souq_listing, class_name: 'Souq::Listing') do
  status { Fabricate(:status) }
  account { |attributes| attributes[:status].account }
  category { Fabricate(:souq_category) }
  category_code { |attributes| attributes[:category].code }
  local true
  title 'Test listing'
  price_mode 'fixed'
  price_minor 1250
  currency { Souq.configuration.default_currency }
  published_at { |attributes| attributes[:status].created_at || Time.current }
end
