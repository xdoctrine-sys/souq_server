# frozen_string_literal: true

module Souq
  module Listings
    # Raised when the `listing` or `status` half of a SOUQ request is rejected.
    #
    # `details` is keyed by the request field name (`listing.price`,
    # `listing.category`, ...) so the API can render
    # `{ "error": ..., "details": { "listing.price": ["..."] } }`.
    class ValidationError < StandardError
      attr_reader :details

      def initialize(details)
        @details = details.each_with_object({}) do |(field, messages), hash|
          hash[field.to_s] = Array(messages)
        end

        super(@details.map { |field, messages| "#{field} #{messages.join(', ')}" }.join('; '))
      end
    end
  end
end
