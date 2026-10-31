# frozen_string_literal: true

module Souq
  class Current < ActiveSupport::CurrentAttributes
    attribute :listing_draft
    attribute :taxonomy_snapshot
  end
end
