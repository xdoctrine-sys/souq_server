# frozen_string_literal: true

module Souq
  module Money
    def self.to_minor(amount, currency:)
      exponent = Configuration::EXPONENTS.fetch(currency) { raise ArgumentError, 'Unsupported currency' }
      raise ArgumentError, 'Amount must be a positive decimal string' unless amount.is_a?(String) && /\A[0-9]+(?:\.[0-9]+)?\z/.match?(amount)

      whole, fraction = amount.split('.', 2)
      fraction ||= ''
      raise ArgumentError, 'Too many decimal places' if fraction.length > exponent

      minor = (whole.to_i * (10**exponent)) + fraction.ljust(exponent, '0').to_i
      raise ArgumentError, 'Amount must be positive' unless minor.positive?
      raise ArgumentError, 'Amount exceeds bigint' if minor > 9_223_372_036_854_775_807

      minor
    end

    def self.to_decimal(minor, currency:)
      exponent = Configuration::EXPONENTS.fetch(currency) { raise ArgumentError, 'Unsupported currency' }
      raise ArgumentError, 'Minor amount must be a positive bigint integer' unless minor.is_a?(Integer) && minor.positive? && minor <= 9_223_372_036_854_775_807

      whole, fraction = minor.divmod(10**exponent)
      "#{whole}.#{fraction.to_s.rjust(exponent, '0')}"
    end
  end
end
