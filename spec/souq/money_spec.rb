# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Souq::Money do
  { 'QAR' => '12.50', 'SAR' => '12.50', 'AED' => '12.50', 'KWD' => '1.250', 'BHD' => '1.250', 'OMR' => '1.250' }.each do |currency, amount|
    it "converts #{currency} #{amount} exactly in both directions" do
      expect(described_class.to_minor(amount, currency:)).to eq(1250)
      expect(described_class.to_decimal(1250, currency:)).to eq(amount)
    end
  end

  ['12.345', '12.500', '-1.00', '0', '0.00', '1e2', 'NaN', '', ' 1.00', '1.', '.50'].each do |amount|
    it "refuses QAR input #{amount.inspect} without rounding" do
      expect { described_class.to_minor(amount, currency: 'QAR') }.to raise_error(ArgumentError)
    end
  end

  it 'refuses non-string input, unsupported currencies and bigint overflow' do
    expect { described_class.to_minor(12.5, currency: 'QAR') }.to raise_error(ArgumentError)
    expect { described_class.to_minor('1', currency: 'USD') }.to raise_error(ArgumentError)
    expect { described_class.to_minor('92233720368547758.08', currency: 'QAR') }.to raise_error(ArgumentError)
  end

  it 'refuses zero, negative and non-integer minor amounts' do
    [0, -1, 1.5, '1250', 9_223_372_036_854_775_808].each do |minor|
      expect { described_class.to_decimal(minor, currency: 'QAR') }.to raise_error(ArgumentError)
    end
  end
end
