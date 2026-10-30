# frozen_string_literal: true

require 'rails_helper'
require 'open3'

RSpec.describe Souq::Configuration do
  it 'provides immutable Qatar defaults without writing data' do
    configuration = described_class.new({})
    expect(configuration.country_code).to eq('QA')
    expect(configuration.default_currency).to eq('QAR')
    expect(configuration.allowed_currencies).to eq(['QAR'])
    expect(configuration).to be_frozen
    expect(configuration.allowed_currencies).to be_frozen
  end

  it 'accepts a trimmed configurable supported currency list' do
    configuration = described_class.new('SOUQ_COUNTRY_CODE' => 'KW', 'SOUQ_DEFAULT_CURRENCY' => 'KWD', 'SOUQ_ALLOWED_CURRENCIES' => 'KWD, QAR,KWD')
    expect(configuration.allowed_currencies).to eq(%w(KWD QAR))
  end

  [
    { 'SOUQ_COUNTRY_CODE' => 'qa' },
    { 'SOUQ_COUNTRY_CODE' => 'QAT' },
    { 'SOUQ_ALLOWED_CURRENCIES' => '' },
    { 'SOUQ_ALLOWED_CURRENCIES' => 'QAR,' },
    { 'SOUQ_ALLOWED_CURRENCIES' => 'USD' },
    { 'SOUQ_DEFAULT_CURRENCY' => 'KWD' },
  ].each do |environment|
    it "refuses invalid configuration #{environment}" do
      expect { described_class.new(environment) }.to raise_error(ArgumentError)
    end
  end

  it 'keeps the same configuration object after boot' do
    expect(Souq.configuration).to equal(Souq.configuration)
  end

  it 'aborts a real Rails boot with invalid configuration' do
    output, errors, status = Open3.capture3({ 'SOUQ_ALLOWED_CURRENCIES' => 'INVALID' }, 'bundle', 'exec', 'rails', 'runner', 'puts "UNREACHABLE"')
    expect(status.success?).to be(false)
    expect(errors).to include('SOUQ_ALLOWED_CURRENCIES must contain supported currency codes')
    expect(output).to_not include('UNREACHABLE')
  end
end
