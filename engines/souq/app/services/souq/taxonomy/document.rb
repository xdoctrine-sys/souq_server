# frozen_string_literal: true

require 'json'

module Souq
  module Taxonomy
    # Parses and validates the versioned JSON document shared by
    # `rake souq:taxonomy:import` and `rake souq:taxonomy:export` (design 7.3).
    #
    # The document is data only. It is checked here, field by field, so that an
    # operator sees every problem at once instead of one model validation at a
    # time. Parsing never writes anything and never invents a label: a value
    # that is missing or malformed is an error, not a default.
    #
    # Sections whose import belongs to another task (attributes in T7,
    # locations in T9) stay in the format so an exported file is
    # self-describing. They must be present and empty for now: T3 refuses to
    # import them rather than drop the data silently.
    class Document
      FORMAT_VERSION = 1
      MAX_DEPTH = 3

      CODE_PATTERN = /\A[a-z0-9_]{2,64}\z/
      COLOR_PATTERN = /\A#[0-9A-Fa-f]{6}\z/
      HTML_ENTITY_PATTERN = /&(?:[a-zA-Z][a-zA-Z0-9]*|#\d+|#x[0-9a-fA-F]+);/

      MARKET_KEYS = %w(code name_en name_ar description_en description_ar icon cover_url color position active categories).freeze
      CATEGORY_KEYS = %w(code parent_code name_en name_ar description_en description_ar icon cover_url color hashtag hashtag_ar position active listable).freeze
      MARKET_STRING_KEYS = %w(description_en description_ar icon cover_url color).freeze
      CATEGORY_STRING_KEYS = %w(description_en description_ar icon cover_url color hashtag hashtag_ar).freeze

      DEFERRED_SECTIONS = { 'attributes' => 'T7', 'locations' => 'T9' }.freeze

      def self.load(path)
        new(::JSON.parse(File.read(path)))
      rescue ::JSON::ParserError => e
        raise InvalidDocumentError, { 'format' => ["is not valid JSON (#{e.message})"] }
      end

      attr_reader :format_version, :taxonomy_version, :markets, :categories

      def initialize(raw)
        @errors = {}
        @raw = raw
        raise InvalidDocumentError, { 'format' => ['must be a JSON object'] } unless raw.is_a?(Hash)

        validate
        raise InvalidDocumentError, @errors if @errors.any?

        @format_version = raw['format_version']
        @taxonomy_version = raw['taxonomy_version']
        @markets = raw['markets']
        @categories = raw['categories']
      end

      def category_codes
        @category_codes ||= @categories.pluck('code')
      end

      def market_codes
        @market_codes ||= @markets.pluck('code')
      end

      private

      def validate
        validate_envelope
        validate_sections
        validate_markets
        validate_categories
        validate_tree
        validate_market_links
      end

      def validate_envelope
        add_error('format_version', "must equal #{FORMAT_VERSION}") unless @raw['format_version'] == FORMAT_VERSION
        version = @raw['taxonomy_version']
        add_error('taxonomy_version', 'must be a positive integer') unless version.is_a?(Integer) && version.positive?
      end

      def validate_sections
        %w(markets categories).each do |section|
          add_error(section, 'must be an array') unless @raw[section].is_a?(Array)
        end
        return unless @raw['markets'].is_a?(Array) && @raw['categories'].is_a?(Array)

        DEFERRED_SECTIONS.each do |section, task|
          value = @raw.fetch(section, [])
          raise UnsupportedSectionError.new(section, task) unless value.is_a?(Array) && value.empty?
        end
        add_error('categories', 'must not be empty') if @raw['categories'].empty?
      end

      def validate_markets
        return unless @raw['markets'].is_a?(Array)

        @raw['markets'].each_with_index do |market, index|
          path = "markets[#{index}]"
          next add_error(path, 'must be an object') unless market.is_a?(Hash)

          validate_keys(market, MARKET_KEYS, path)
          validate_code(market['code'], "#{path}.code")
          validate_labels(market, path)
          validate_optional_strings(market, MARKET_STRING_KEYS, path)
          validate_position(market['position'], "#{path}.position")
          validate_boolean(market['active'], "#{path}.active")
          validate_string_list(market['categories'], "#{path}.categories")
        end
        validate_unique(market_codes_of(@raw['markets']), 'markets', 'code')
      end

      def validate_categories
        return unless @raw['categories'].is_a?(Array)

        @raw['categories'].each_with_index do |category, index|
          path = "categories[#{index}]"
          next add_error(path, 'must be an object') unless category.is_a?(Hash)

          validate_keys(category, CATEGORY_KEYS, path)
          validate_code(category['code'], "#{path}.code")
          validate_code(category['parent_code'], "#{path}.parent_code") unless category['parent_code'].nil?
          validate_labels(category, path)
          validate_optional_strings(category, CATEGORY_STRING_KEYS, path)
          validate_hashtags(category, path)
          validate_position(category['position'], "#{path}.position")
          validate_boolean(category['active'], "#{path}.active")
          validate_boolean(category['listable'], "#{path}.listable")
        end
        validate_unique(category_codes_of(@raw['categories']), 'categories', 'code')
      end

      # Every parent must be resolved inside the document, no cycle is allowed
      # and the depth must stay within the database limit.
      def validate_tree
        return unless readable?('categories')

        by_code = @raw['categories'].index_by { |category| category['code'] }
        @raw['categories'].each do |category|
          parent = category['parent_code']
          add_error("categories[#{category['code']}].parent_code", 'is unknown in this document') if parent && !by_code.key?(parent)

          depth = resolve_depth(category, by_code)
          if depth == :cycle
            add_error("categories[#{category['code']}]", 'creates a cycle')
          elsif depth && depth > MAX_DEPTH
            add_error("categories[#{category['code']}]", "exceeds maximum depth #{MAX_DEPTH}")
          end
        end
        validate_unique(
          @raw['categories'].map { |category| [category['parent_code'], category['position']] },
          'categories', 'position within one parent'
        )
      end

      def validate_market_links
        return unless readable?('categories') && readable?('markets')

        codes = category_codes_of(@raw['categories'])
        @raw['markets'].each do |market|
          linked = market['categories']
          linked.each do |code|
            add_error("markets[#{market['code']}].categories", "references unknown category #{code}") unless codes.include?(code)
          end
          validate_unique(linked, "markets[#{market['code']}].categories", 'category')
        end
      end

      # True when the section can be read without a nil dereference: the
      # section is a valid array and nothing is wrong with the entries so far.
      def readable?(section)
        @errors.empty? && @raw[section].is_a?(Array)
      end

      def market_codes_of(markets)
        markets.filter_map { |market| market['code'] if market.is_a?(Hash) }
      end

      def category_codes_of(categories)
        categories.filter_map { |category| category['code'] if category.is_a?(Hash) }
      end

      # Walks up to the root. Returns the depth (a root is 0), :cycle when a
      # code appears twice in its own chain, or nil when a parent is unknown.
      def resolve_depth(category, by_code)
        depth = 0
        seen = []
        current = category
        while current
          return :cycle if seen.include?(current['code'])

          seen << current['code']
          parent = current['parent_code']
          return depth if parent.nil?
          return nil unless by_code.key?(parent)

          depth += 1
          current = by_code[parent]
        end
        depth
      end

      def validate_keys(entry, allowed, path)
        missing = allowed - entry.keys
        extra = entry.keys - allowed
        add_error(path, "is missing #{missing.join(', ')}") if missing.any?
        add_error(path, "has unknown keys #{extra.join(', ')}") if extra.any?
      end

      def validate_code(value, path)
        add_error(path, 'must be a string') unless value.is_a?(String)
        add_error(path, 'must match /\\A[a-z0-9_]{2,64}\\z/') if value.is_a?(String) && !CODE_PATTERN.match?(value)
      end

      def validate_labels(entry, path)
        %w(name_en name_ar).each do |key|
          value = entry[key]
          if !value.is_a?(String) || value.empty?
            add_error("#{path}.#{key}", 'must be a non-empty string')
          elsif value != value.strip
            add_error("#{path}.#{key}", 'must not have leading or trailing whitespace')
          elsif HTML_ENTITY_PATTERN.match?(value)
            add_error("#{path}.#{key}", 'must not contain an HTML entity')
          end
        end
      end

      def validate_optional_strings(entry, keys, path)
        keys.each do |key|
          value = entry[key]
          add_error("#{path}.#{key}", 'must be a string or null') unless value.nil? || value.is_a?(String)
        end
      end

      def validate_hashtags(entry, path)
        %w(hashtag hashtag_ar).each do |key|
          value = entry[key]
          next if value.nil?
          next if value.is_a?(String) && value == value.downcase && ::Tag::HASHTAG_NAME_RE.match?(value)

          add_error("#{path}.#{key}", 'must be a lowercase Mastodon hashtag')
        end
      end

      def validate_position(value, path)
        add_error(path, 'must be a non-negative integer') unless value.is_a?(Integer) && value >= 0
      end

      def validate_boolean(value, path)
        add_error(path, 'must be true or false') unless [true, false].include?(value)
      end

      def validate_string_list(value, path)
        add_error(path, 'must be an array of strings') unless value.is_a?(Array) && value.all?(String)
      end

      def validate_unique(values, path, label)
        duplicates = values.tally.select { |_value, count| count > 1 }.keys
        add_error(path, "has duplicate #{label} #{duplicates.join(', ')}") if duplicates.any?
      end

      def add_error(path, message)
        (@errors[path] ||= []) << message
      end
    end
  end
end
