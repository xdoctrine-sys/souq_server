# frozen_string_literal: true

module Souq
  module Listings
    # Updates the SOUQ half of a listing (title, price, location) and, when the
    # request carries a new status text, the Mastodon half too.
    #
    # The update is a full replacement of the listing fields (PUT semantics);
    # the category is immutable until T11b. Both writes run in one transaction so
    # a rejected status edit rolls the listing back.
    #
    # `UpdateStatusService#broadcast_updates!` runs after its own transaction, so
    # the streaming event may be enqueued before this transaction commits. See
    # T11a_RAPPORT.md for the residual window and the proposed upstream change.
    class Update
      def self.call(listing, status_params:, listing_params:)
        new(listing, status_params: status_params, listing_params: listing_params).call
      end

      def initialize(listing, status_params:, listing_params:)
        @listing = listing
        @status = listing.status
        @status_params = (status_params || {}).to_h.symbolize_keys
        @listing_params = (listing_params || {}).to_h.symbolize_keys
      end

      def call
        input = Input.new(@listing_params, category_required: false).validate!
        reject_category_change!(input)

        text = @status_params[:text]
        text_changed = text.present? && text.to_s != @status.text

        ApplicationRecord.transaction do
          apply_listing!(input)
          UpdateStatusService.new.call(@status, @status.account_id, text: text) if text_changed
        end

        # A text change already broadcasts through UpdateStatusService; without
        # one, the listing refresh must be sent explicitly (design section 5.4).
        DistributionWorker.perform_async(@status.id, { 'update' => true }) unless text_changed

        @listing
      end

      private

      def reject_category_change!(input)
        return if input.category.nil? || input.category.id == @listing.category_id

        raise ValidationError, { 'listing.category' => ['cannot be changed yet'] }
      end

      def apply_listing!(input)
        attributes = input.normalized
        @listing.assign_attributes(
          title: attributes[:title],
          price_mode: attributes[:price_mode],
          price_minor: attributes[:price_minor],
          currency: attributes[:currency],
          price_period: attributes[:price_period],
          location: attributes[:location]
        )
        @listing.save!
      end
    end
  end
end
