# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'

RSpec.describe Souq::Location do # rubocop:disable RSpec/SpecFilePathFormat
  it 'initializes a region, city and area with consistent ancestry' do
    region = Fabricate(:souq_location)
    city = Fabricate(:souq_location, parent: region, kind: 'city')
    area = Fabricate(:souq_location, parent: city, kind: 'area')
    expect(region.ancestor_ids).to eq([])
    expect(city.ancestor_ids).to eq([region.id])
    expect(area.ancestor_ids).to eq([region.id, city.id])
    expect(area.depth).to eq(2)
    expect(Fabricate.build(:souq_location, parent: area, kind: 'area')).to_not be_valid
  end

  it 'refuses a non-root region and a root city or area' do
    region = Fabricate(:souq_location)
    expect(Fabricate.build(:souq_location, parent: region)).to_not be_valid
    %w(city area).each do |kind|
      expect(Fabricate.build(:souq_location, kind:)).to_not be_valid
    end
  end

  it 'validates code, names, position, active and enum values' do
    [
      { code: 'BAD' }, { name_en: '' }, { name_ar: '' },
      { position: -1 }, { active: nil }, { kind: 9 }
    ].each do |attributes|
      expect(Fabricate.build(:souq_location, **attributes)).to_not be_valid
    end
  end

  it 'refuses code changes and deletion of a parent with children' do
    region = Fabricate(:souq_location)
    Fabricate(:souq_location, parent: region, kind: 'city')
    region.code = 'new_code'
    expect(region).to_not be_valid
    expect(region.destroy).to be(false)
    expect(described_class.exists?(region.id)).to be(true)
  end
end
