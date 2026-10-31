# frozen_string_literal: true

module Souq
  module Listings
    # Updates the SOUQ half of a listing (title, price, location) and, when the
    # request carries a new status text, the Mastodon half too.
    #
    # The update is a full replacement of the listing fields (PUT semantics);
    # the category is immutable until T11b.
    #
    # When the text changes, the listing fields are applied by the
    # `Status.after_update` callback declared in Souq::StatusExtension, inside
    # the transaction UpdateStatusService opens around `@status.save!`. The
    # distribution jobs are enqueued after that transaction commits, so they
    # already carry the new text and the new listing, and a rejected edit rolls
    # the status and the listing back together.
    class Update
      def self.call(listing, status_params:, listing_params:)
        new(listing, status_params: status_params, listing_params: listing_params).call
      end

      # Called by the Status after_update callback with the normalized draft,
      # inside the status transaction. It marks the draft as consumed so the
      # outer service does not write the listing a second time.
      def self.apply!(_status, draft)
        listing = Souq::Listing.find(draft[:listing_id])
        listing.update!(draft[:attributes])
        draft[:consumed] = true
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

        if text_changed
          Souq::Current.listing_update = {
            status_id: @status.id,
            listing_id: @listing.id,
            attributes: listing_attributes(input),
            consumed: false,
          }
          UpdateStatusService.new.call(@status, @status.account_id, text: text)
        end

        # A text change already wrote the listing inside UpdateStatusService's
        # transaction, and that service broadcast the update after the commit.
        # Otherwise (no text change, or a swallowed NoChangesSubmittedError) the
        # listing refresh is written and broadcast here, after the commit, with
        # `skip_notifications`: a price or state refresh must not notify the
        # accounts that shared the status.
        unless consumed?
          @listing.update!(listing_attributes(input))
          DistributionWorker.perform_async(@status.id, { 'update' => true, 'skip_notifications' => true })
        end

        @listing
      ensure
        Souq::Current.listing_update = nil
      end

      private

      def consumed?
        Souq::Current.listing_update.present? && Souq::Current.listing_update[:consumed]
      end

      def reject_category_change!(input)
        return if input.category.nil? || input.category.id == @listing.category_id

        raise ValidationError, { 'listing.category' => ['cannot be changed yet'] }
      end

      # Normalized, plain-valued attributes: no ActiveRecord object may reach
      # Souq::Current, so the location is stored as an id.
      def listing_attributes(input)
        normalized = input.normalized
        {
          title: normalized[:title],
          price_mode: normalized[:price_mode],
          price_minor: normalized[:price_minor],
          currency: normalized[:currency],
          price_period: normalized[:price_period],
          location_id: normalized[:location]&.id,
        }
      end
    end
  end
end
