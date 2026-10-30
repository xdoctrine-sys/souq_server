# frozen_string_literal: true

module Souq
  module DemoSeed
    def self.run!(environment: Rails.env)
      raise ArgumentError, 'SOUQ demo seed is forbidden in production' if environment.to_s == 'production'

      ApplicationRecord.transaction do
        vehicles = Category.find_or_create_by!(code: 'vehicles') do |category|
          category.name_en = 'Vehicles'
          category.name_ar = 'مركبات'
        end
        Category.find_or_create_by!(code: 'cars') do |category|
          category.parent = vehicles
          category.name_en = 'Cars'
          category.name_ar = 'سيارات'
        end
        motors = Market.find_or_create_by!(code: 'motors') do |market|
          market.name_en = 'Motors'
          market.name_ar = 'محركات'
        end
        MarketCategory.find_or_create_by!(market: motors, category: vehicles)
        if ApplicationRecord.connection.data_source_exists?('souq_locations')
          region = Location.find_or_create_by!(code: 'demo_region') do |location|
            location.name_en = 'Demo region'
            location.name_ar = 'منطقة تجريبية'
            location.kind = 'region'
          end
          Location.find_or_create_by!(code: 'demo_city') do |location|
            location.parent = region
            location.name_en = 'Demo city'
            location.name_ar = 'مدينة تجريبية'
            location.kind = 'city'
          end
        end
      end
    end
  end
end
