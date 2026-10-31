# frozen_string_literal: true

module Souq
  module Categories
    class ValidationError < StandardError
      attr_reader :details

      def initialize(details)
        @details = details
        super('invalid category operation')
      end
    end
  end
end
