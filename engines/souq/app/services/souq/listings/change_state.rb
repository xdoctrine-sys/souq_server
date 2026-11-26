# frozen_string_literal: true

module Souq
  module Listings
    # Moves a listing between the states its owner may set and refreshes the
    # cards already displayed (design section 5.4): the status itself is not
    # edited, so no `edited_at` and no revision is created.
    #
    # Because the refresh is broadcast like a status edit, it consumes the very
    # same `statuses` rate-limit quota with the shared RateLimiter; the quota is
    # rolled back if the state write fails.
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

        consume_rate_limit!

        begin
          ApplicationRecord.transaction do
            @listing.state = @state
            @listing.sold_at = Time.current if @state == 'sold'
            @listing.sold_at = nil if @state == 'active'
            @listing.save!
          end

          # Enqueued after the commit, never inside the transaction. The status
          # text itself is not edited, so the accounts that shared it must not be
          # notified: `skip_notifications` keeps the feed refresh silent.
          DistributionWorker.perform_async(@listing.status_id, { 'update' => true, 'skip_notifications' => true })
        rescue
          rollback_rate_limit!
          raise
        end

        # Reload so the serialized status carries the committed state instead of
        # an association cached before the write.
        @listing.reload
      end

      private

      def consume_rate_limit!
        rate_limiter.record!
        @rate_limit_recorded = true
      end

      def rollback_rate_limit!
        rate_limiter.rollback! if @rate_limit_recorded
        @rate_limit_recorded = false
      end

      def rate_limiter
        @rate_limiter ||= RateLimiter.new(@listing.account, family: :statuses)
      end

      def validate!
        raise ValidationError, { 'listing.state' => ["must be one of #{OWNER_STATES.join(', ')}"] } unless OWNER_STATES.include?(@state)

        return unless LOCKED_STATES.include?(@listing.state)

        raise ValidationError, { 'listing.state' => ['cannot be changed by the owner'] }
      end
    end
  end
end
