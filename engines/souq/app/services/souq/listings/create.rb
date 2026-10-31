# frozen_string_literal: true

module Souq
  module Listings
    # Creates a Mastodon status and its SOUQ listing from a single request.
    #
    # The listing row is inserted by the `Status.after_create` callback declared
    # in Souq::StatusExtension, inside the transaction PostStatusService opens
    # around `@status.save!`. A rejected listing therefore cancels the status and
    # no distribution job is enqueued (design section 5.2, point 6).
    class Create
      ALLOWED_VISIBILITIES = %w(public unlisted).freeze

      # Called by the Status after_create callback with the normalized draft. It
      # runs inside the status transaction: raising here cancels the status.
      def self.attach!(status, draft)
        Souq::Listing.create!(
          status: status,
          account_id: status.account_id,
          category: draft[:category],
          category_code: draft[:category].code,
          local: status.local?,
          title: draft[:title],
          price_mode: draft[:price_mode],
          price_minor: draft[:price_minor],
          currency: draft[:currency],
          price_period: draft[:price_period],
          location: draft[:location],
          attribute_values: {},
          state: :active,
          published_at: status.created_at
        )
      end

      def self.call(account, status:, listing:, application: nil, idempotency: nil)
        new(account, status: status, listing: listing, application: application, idempotency: idempotency).call
      end

      def initialize(account, status:, listing:, application: nil, idempotency: nil)
        @account = account
        @status_params = (status || {}).to_h.symbolize_keys
        @listing_params = (listing || {}).to_h.symbolize_keys
        @application = application
        @idempotency = idempotency
      end

      # Returns the created Status and raises Souq::Listings::ValidationError
      # (rendered as 422 by the controller) before touching the database when the
      # request is rejected.
      def call
        input = Input.new(@listing_params).validate!
        @status_params[:visibility] = resolve_visibility!

        @status_params[:text] = append_hashtag(@status_params[:text].to_s, input.category)
        ensure_text_fits!(@status_params[:text])

        Souq::Current.listing_draft = input.normalized

        PostStatusService.new.call(@account, post_options)
      ensure
        Souq::Current.listing_draft = nil
      end

      private

      def resolve_visibility!
        details = {}
        details['status.scheduled_at'] = ['is not supported for listings'] if @status_params[:scheduled_at].present?

        visibility = @status_params[:visibility].presence&.to_s || @account.user&.setting_default_privacy&.to_s || 'public'
        details['status.visibility'] = ['must be public or unlisted'] unless ALLOWED_VISIBILITIES.include?(visibility)

        raise ValidationError, details unless details.empty?

        visibility
      end

      # Adds the category hashtag once, case-insensitively, so the status is
      # discoverable on any server. ProcessHashtagsService rebuilds tags from the
      # text, so an invisible tag would be dropped (design section 5.2, point 3).
      def append_hashtag(text, category)
        hashtag = category.hashtag
        return text if hashtag.blank? || hashtag_in?(text, hashtag)

        text.rstrip.empty? ? "##{hashtag}" : "#{text.rstrip} ##{hashtag}"
      end

      def hashtag_in?(text, hashtag)
        Extractor.extract_hashtags_with_indices(text).any? { |entity| entity[:hashtag].casecmp?(hashtag) }
      end

      # Checks the limit with the server's own validator so URLs and mentions get
      # the same concessions as a normal post.
      def ensure_text_fits!(text)
        probe = @account.statuses.new(text: text, spoiler_text: @status_params[:spoiler_text].to_s)
        StatusLengthValidator.new({}).validate(probe)
        return if probe.errors[:text].empty?

        raise ValidationError, { 'status.status' => ["is too long (maximum is #{StatusLengthValidator::MAX_CHARS} characters)"] }
      end

      # Same options as Api::V1::StatusesController#create, minus the ones SOUQ
      # does not support yet (threads, quotes, polls, scheduled statuses).
      def post_options
        {
          text: @status_params[:text],
          visibility: @status_params[:visibility],
          language: @status_params[:language],
          sensitive: @status_params[:sensitive],
          spoiler_text: @status_params[:spoiler_text],
          media_ids: @status_params[:media_ids],
          application: @application,
          idempotency: @idempotency,
          with_rate_limit: true,
        }
      end
    end
  end
end
