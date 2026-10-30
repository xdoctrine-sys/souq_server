# frozen_string_literal: true

module Souq
  class Configuration
    EXPONENTS = { 'QAR' => 2, 'SAR' => 2, 'AED' => 2, 'KWD' => 3, 'BHD' => 3, 'OMR' => 3 }.freeze

    attr_reader :country_code, :default_currency, :allowed_currencies

    def initialize(environment = ENV)
      @country_code = environment.fetch('SOUQ_COUNTRY_CODE', 'QA')
      @default_currency = environment.fetch('SOUQ_DEFAULT_CURRENCY', 'QAR')
      @allowed_currencies = environment.fetch('SOUQ_ALLOWED_CURRENCIES', 'QAR').split(',', -1).map { |code| code.strip.freeze }.uniq.freeze
      raise ArgumentError, 'SOUQ_COUNTRY_CODE must be two uppercase ASCII letters' unless /\A[A-Z]{2}\z/.match?(@country_code)
      raise ArgumentError, 'SOUQ_ALLOWED_CURRENCIES must contain supported currency codes' if @allowed_currencies.empty? || (@allowed_currencies - EXPONENTS.keys).any?
      raise ArgumentError, 'SOUQ_DEFAULT_CURRENCY must be allowed' unless @allowed_currencies.include?(@default_currency)

      @country_code.freeze
      @default_currency.freeze
      freeze
    end
  end

  def self.configuration
    @configuration ||= Configuration.new
  end
end
