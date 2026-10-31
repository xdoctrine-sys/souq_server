# frozen_string_literal: true

module Souq
  module Listings
    # Moves a listing between the states its owner may set and refreshes the
    # cards already displayed (design section 5.4): the status itself is not
    # edited, so no `edited_at` and no revision is created.
    class ChangeState
      OWNER_STATES = %w(active reserved sold).freeze
      LOCKED_STATES = %w(expired hidden).freeze

      def self.call(listing, state)
        new(listing, state).call
      end

      def initialize(listing, state)
        @listing = listing
        @state = state.to_s
      end

      def call
        validate!
        return @listing if @listing.state == @state

        ApplicationRecord.transaction do
          @listing.state = @state
          @listing.sold_at = Time.current if @state == 'sold'
          @listing.sold_at = nil if @state == 'active'
          @listing.save!
        end

        # Enqueued after the commit, never inside the transaction. The status text
        # itself is not edited, so the accounts that shared it must not be
        # notified: `skip_notifications` keeps the feed refresh silent.
        DistributionWorker.perform_async(@listing.status_id, { 'update' => true, 'skip_notifications' => true })

        @listing
      end

      private

      def validate!
        raise ValidationError, { 'listing.state' => ["must be one of #{OWNER_STATES.join(', ')}"] } unless OWNER_STATES.include?(@state)

        return unless LOCKED_STATES.include?(@listing.state)

        raise ValidationError, { 'listing.state' => ['cannot be changed by the owner'] }
      end
    end
  end
end
