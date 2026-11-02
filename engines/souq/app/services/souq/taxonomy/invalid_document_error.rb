# frozen_string_literal: true

module Souq
  module Taxonomy
    # Raised when a document is structurally invalid. `details` maps a
    # JSON path (for example `categories[12].code`) to the list of problems,
    # mirroring ActiveRecord::Errors#to_hash so a caller can print every
    # problem at once instead of one at a time.
    class InvalidDocumentError < Error
      attr_reader :details

      def initialize(details)
        @details = details
        super('invalid SOUQ taxonomy document')
      end
    end
  end
end
