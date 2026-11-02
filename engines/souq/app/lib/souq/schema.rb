# frozen_string_literal: true

module Souq
  # Effective attribute schema (SOUQ_CATEGORIES_DESIGN.md section 3.4).
  #
  # The schema of a category is the ordered, immutable list of attributes it
  # exposes, computed from the rules of its ancestors and of itself, root
  # first. Problems are plain data objects so callers can render them without
  # parsing strings.
  module Schema
    # A single, machine-readable problem or warning.
    #
    # `category` is the category code, `attribute` the attribute code (nil for
    # a category-wide problem), `code` a stable machine token and `message` a
    # human-readable sentence. No free text is ever stored about a write.
    Issue = Struct.new(:category, :attribute, :code, :message, keyword_init: true) do
      def to_h
        { category: category, attribute: attribute, code: code, message: message }
      end
    end

    # The resolved schema of one category for one taxonomy version.
    #
    # `attributes` is a deeply frozen, ordered array. `invalid?` is true as
    # soon as the rules cannot be resolved (a direct SQL write, a broken
    # import), which the endpoint renders as 503 and the validator refuses.
    class Result
      attr_reader :attributes, :issues, :warnings

      def initialize(attributes:, issues: [], warnings: [])
        @attributes = attributes
        @issues = issues
        @warnings = warnings
        freeze
      end

      def invalid?
        @issues.any?
      end

      def attribute(code)
        @attributes.find { |entry| entry[:code] == code.to_s }
      end

      def codes
        @attributes.pluck(:code)
      end
    end

    # Carries the payload of the public schema endpoint to its serializer.
    #
    # ActiveModelSerializers asks the object class for `model_name` to compute
    # the resource root. ActiveModel::Naming exposes it through its `extended`
    # hook, so the envelope extends it instead of raising on a bare Struct.
    Envelope = Struct.new(:category, :taxonomy_version, :attributes, keyword_init: true) do
      extend ActiveModel::Naming
    end

    class Error < StandardError; end

    # Raised when a rule write is rejected before it touches the schema: a
    # missing actor, an unknown category or definition, or a model validation.
    # `details` is a hash keyed by field name, like the category services.
    class ValidationError < Error
      attr_reader :details

      def initialize(details)
        @details = details
        super('invalid attribute rule operation')
      end
    end

    # Raised when a category or a definition referenced by a rule does not
    # exist.
    class NotFoundError < Error; end

    # Raised by the rule write services. The issues are grouped by category
    # code then attribute code so the admin UI can show them per row.
    class RuleError < Error
      attr_reader :issues

      def initialize(issues)
        @issues = Array(issues)
        super('invalid attribute rule')
      end

      def details
        @issues.each_with_object({}) do |issue, hash|
          by_attribute = (hash[issue.category] ||= {})
          (by_attribute[issue.attribute] ||= []) << { code: issue.code, message: issue.message }
        end
      end
    end
  end
end
