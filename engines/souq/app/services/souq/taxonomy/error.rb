# frozen_string_literal: true

module Souq
  module Taxonomy
    # Base class for every error raised while reading or applying a taxonomy
    # document. Callers (rake tasks, admin API in T7) rescue this single class.
    class Error < StandardError; end
  end
end
