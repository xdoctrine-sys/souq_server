# frozen_string_literal: true

module Souq
  module Taxonomy
    # Raised when an import cannot even start (for example an unknown actor).
    # `details` maps a field to the list of problems, mirroring
    # Souq::Categories::ValidationError so callers treat both the same way.
    class ValidationError < Error
      attr_reader :details

      def initialize(details)
        @details = details
        super('invalid taxonomy import')
      end
    end
  end
end
