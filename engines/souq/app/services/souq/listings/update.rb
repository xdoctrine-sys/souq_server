# frozen_string_literal: true

module Souq
  module Listings
    # Updates the SOUQ half of a listing (title, price, location) and, when the
    # request carries a new status text, the Mastodon half too.
    #
    # The update is a full replacement of the listing fields (PUT semantics);
    # the category is immutable until T11b.
    #
    # When the status half changes (new text or a media selection), the listing
    # fields are applied by the `Status.after_update` callback declared in
    # Souq::StatusExtension, inside the transaction UpdateStatusService opens
    # around `@status.save!`. The distribution jobs are enqueued after that
    # transaction commits, so they already carry the new text and the new
    # listing, and a rejected edit rolls the status and the listing back
    # together. That edit consumes the account's `statuses` rate-limit quota
    # through the `StatusEdit` snapshot.
    #
    # When only the listing fields change, this service writes them and
    # broadcasts the refresh itself, exactly like a status edit would, and
    # consumes the very same `statuses` quota with the shared RateLimiter so a
    # price or a title refresh cannot be used to broadcast for free.
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

        if status_half_changes?
          Souq::Current.listing_update = {
            status_id: @status.id,
            listing_id: @listing.id,
            attributes: listing_attributes(input),
            consumed: false,
          }
          UpdateStatusService.new.call(@status, @status.account_id, status_update_options)
        end

        # A status change already wrote the listing inside UpdateStatusService's
        # transaction, consumed the rate-limit quota through the StatusEdit, and
        # broadcast the update after the commit. Otherwise the listing refresh is
        # written and broadcast here, after the commit, with `skip_notifications`:
        # a price or state refresh must not notify the accounts that shared the
        # status. It still counts against the `statuses` quota, like an edit.
        unless consumed?
          consume_rate_limit!
          begin
            @listing.update!(listing_attributes(input))
            DistributionWorker.perform_async(@status.id, { 'update' => true, 'skip_notifications' => true })
          rescue
            rollback_rate_limit!
            raise
          end
        end

        # The returned listing (and the status the controller serializes) must
        # carry the committed values: when the text changed, the fields were
        # written through a different instance inside the status transaction, and
        # the `souq_listing` association may already be cached on the status.
        @listing.reload
      ensure
        Souq::Current.listing_update = nil
      end

      private

      def consumed?
        Souq::Current.listing_update.present? && Souq::Current.listing_update[:consumed]
      end

      def text_changed?
        text = @status_params[:text]
        text.present? && text.to_s != @status.text
      end

      # The status half is routed through UpdateStatusService when the request
      # asks for a text change or carries a media selection (upstream
      # `PUT /api/v1/statuses/:id` forwards `media_ids`/`media_attributes` and the
      # controller already permits them). The listing half alone is written by
      # this service.
      def status_half_changes?
        text_changed? || @status_params.key?(:media_ids)
      end

      def status_update_options
        options = {}
        options[:text] = @status_params[:text] if text_changed?
        options[:media_ids] = @status_params[:media_ids] if @status_params.key?(:media_ids)
        options[:media_attributes] = media_attributes if @status_params.key?(:media_attributes)
        options
      end

      # The nested `media_attributes` entries reached us as plain hashes with
      # string keys (the controller flattens the request with `to_h`), and
      # UpdateStatusService reads them with symbol keys.
      def media_attributes
        Array(@status_params[:media_attributes]).map { |attributes| attributes.to_h.symbolize_keys }
      end

      def consume_rate_limit!
        rate_limiter.record!
        @rate_limit_recorded = true
      end

      def rollback_rate_limit!
        rate_limiter.rollback! if @rate_limit_recorded
        @rate_limit_recorded = false
      end

      def rate_limiter
        @rate_limiter ||= RateLimiter.new(@status.account, family: :statuses)
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
