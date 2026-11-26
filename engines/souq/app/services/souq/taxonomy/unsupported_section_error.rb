# frozen_string_literal: true

module Souq
  module Taxonomy
    # Raised when a document carries a section whose import belongs to another
    # task. The section is part of the format so an exported file stays
    # self-describing, but T3 refuses to import it rather than silently drop
    # the data.
    class UnsupportedSectionError < Error
      attr_reader :section, :task

      def initialize(section, task)
        @section = section
        @task = task
        super("section #{section} is not imported yet (planned in #{task})")
      end
    end
  end
end
