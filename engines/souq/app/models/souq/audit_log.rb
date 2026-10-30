# frozen_string_literal: true

module Souq
  class AuditLog < ApplicationRecord
    ACTIONS = %w(create update move reorder activate deactivate import).freeze

    belongs_to :account, class_name: '::Account'

    validates :action, inclusion: { in: ACTIONS }
    validates :target_type, presence: true
    validates :target_id, numericality: { only_integer: true, greater_than: 0 }
    validates :recorded_changes, exclusion: { in: [nil] }
  end
end
