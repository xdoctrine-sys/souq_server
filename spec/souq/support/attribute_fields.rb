# frozen_string_literal: true

require_relative 'attributes'

RSpec.shared_examples 'SOUQ attribute fields' do |fabricator|
  %w(name_en name_ar).each do |field|
    it "requires #{field}" do
      record = Fabricate.build(fabricator)
      expect(record).to be_valid
      record.public_send("#{field}=", '')
      expect(record).to_not be_valid
      expect(record.errors[field]).to be_present
    end
  end

  ['X_code', 'x', 'a' * 65, 'bad-code', "code\n"].each do |code|
    it "rejects malformed code #{code.inspect}" do
      record = Fabricate.build(fabricator, code:)
      expect(record).to_not be_valid
      expect(record.errors[:code]).to be_present
    end
  end

  it 'accepts both code length limits' do
    expect(Fabricate.build(fabricator, code: 'ab')).to be_valid
    expect(Fabricate.build(fabricator, code: 'a' * 64)).to be_valid
  end

  it 'keeps persisted codes immutable' do
    record = Fabricate(fabricator)
    record.code = 'replacement'
    expect(record).to_not be_valid
    expect(record.errors[:code]).to include('is immutable')
  end

  it 'requires nonnegative integer positions' do
    record = Fabricate.build(fabricator, position: 0)
    expect(record).to be_valid
    record.position = -1
    expect(record).to_not be_valid
    expect(record.errors[:position]).to be_present
  end

  it 'requires an active boolean and defaults it to true' do
    record = Fabricate.build(fabricator)
    expect(record.active).to be(true)
    record.active = nil
    expect(record).to_not be_valid
    expect(record.errors[:active]).to be_present
  end
end
