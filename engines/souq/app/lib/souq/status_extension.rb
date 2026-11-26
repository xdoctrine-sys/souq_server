# frozen_string_literal: true

module Souq
  # Single, reload-safe entry point that extends Mastodon's Status and the
  # ordinary read surfaces for SOUQ.
  #
  # It is called from config/initializers/souq.rb inside a `to_prepare` block
  # and stays idempotent so that code reloading in development (which re-runs
  # `to_prepare`) never adds the same attribute or prepend twice.
  module StatusExtension
    # Status ids whose SOUQ listing sits in the moderation state `hidden`
    # (design section 3.6 and 5.3). Those statuses must leave every *public*
    # read surface, the same way a status the reader may not see does: the
    # client only hides the card, so without this the post text and its media
    # stay readable through the status and timeline endpoints (audit M-05.4).
    #
    # The owner keeps access (see StatusPolicyMethods#show?), following
    # Mastodon's own convention that an author always resolves their own
    # status; the platform locks the *state transition*, not the read.
    HIDDEN_LISTING_STATUS_IDS = -> { Souq::Listing.state_hidden.select(:status_id) }

    module StatusPolicyMethods
      # `record` is a Status. A hidden listing is not readable by anyone except
      # its owner, so both `GET /api/v1/statuses/:id` and the SOUQ read API
      # (`GET /api/v1/souq/listings/:id`, which authorizes the same policy)
      # answer the same 404 as an unknown id.
      def show?
        return false if record.souq_listing&.state_hidden? && !owned?

        super
      end
    end

    module PublicFeedMethods
      def public_scope
        super.where.not(id: HIDDEN_LISTING_STATUS_IDS.call)
      end
    end

    module AccountStatusesFilterMethods
      # A hidden listing leaves its author's profile too, but the author keeps
      # seeing it on their own profile.
      def initial_scope
        return super if current_account == account

        super.where.not(id: Souq::Listing.state_hidden.where(account_id: account.id).select(:status_id))
      end
    end

    module FeedMethods
      def from_redis(limit, max_id, since_id, min_id)
        super.where.not(id: HIDDEN_LISTING_STATUS_IDS.call)
      end
    end

    def self.apply!
      return if @applied

      ::Status.has_one :souq_listing, class_name: 'Souq::Listing', inverse_of: :status

      # Mirror the declaration in app/models/status.rb and add the SOUQ
      # association, so timelines preload it instead of querying once per
      # status.
      ::Status.cache_associated(
        *::Status::CACHEABLE_ASSOCIATIONS, :souq_listing,
        reblog: [*::Status::CACHEABLE_ASSOCIATIONS, :souq_listing],
        thread: :account
      )

      # Resolve the parent serializer first: the reverse order triggers a
      # circular dependency (StatusSerializer -> QuoteSerializer ->
      # ShallowStatusSerializer) and raises a NameError with lazy loading.
      #
      # ActiveModelSerializers copies a subclass' attributes at definition
      # time, so the attribute must be added to both classes explicitly.
      [::REST::StatusSerializer, ::REST::ShallowStatusSerializer].each do |serializer|
        serializer.attribute :souq_listing, if: -> { object.souq_listing.present? } do
          Souq::REST::ListingSerializer.new(object.souq_listing).as_json
        end
      end

      # Attach the listing inside the transaction PostStatusService opens
      # around `@status.save!`: if the listing is rejected, the status rolls
      # back with it and no distribution job is enqueued. The draft guard keeps
      # ordinary statuses and the standard Mastodon API untouched.
      #
      # Declared only once: in development `to_prepare` re-runs after each code
      # reload, which resets @applied, and a second declaration would attach the
      # listing twice.
      ::Status.define_method(:souq_attach_listing) do
        Souq::Listings::Create.attach!(self, Souq::Current.listing_draft)
      end

      ::Status.after_create :souq_attach_listing, if: -> { local? && Souq::Current.listing_draft.present? } unless ::Status._create_callbacks.any? { |callback| callback.filter == :souq_attach_listing }

      # Apply the SOUQ listing edit inside the transaction UpdateStatusService
      # opens around `@status.save!`, exactly like the creation callback above.
      # The `after_update` hook fires while the status row is still uncommitted,
      # so a failure in any later step of the service cancels the status and the
      # listing together, and the distribution jobs enqueued after the commit
      # already carry the new content.
      #
      # The draft holds normalized values and ids only (never an ActiveRecord
      # object), and its `consumed` flag makes sure the listing is written once
      # even if the status is saved again later in the same call (e.g. by
      # ProcessHashtagsService).
      ::Status.define_method(:souq_apply_listing_update) do
        Souq::Listings::Update.apply!(self, Souq::Current.listing_update)
      end

      ::Status.after_update :souq_apply_listing_update, if: -> { Souq::Current.listing_update.present? && !Souq::Current.listing_update[:consumed] && Souq::Current.listing_update[:status_id] == id } unless ::Status._update_callbacks.any? { |callback| callback.filter == :souq_apply_listing_update }

      # Remove hidden listings from every local read surface the reader can hit
      # directly. `StatusPolicy` covers the status and SOUQ read APIs, the other
      # three cover the timelines (public, profile, redis-backed home).
      ::StatusPolicy.prepend(StatusPolicyMethods) unless ::StatusPolicy <= StatusPolicyMethods
      ::PublicFeed.prepend(PublicFeedMethods) unless ::PublicFeed <= PublicFeedMethods
      ::AccountStatusesFilter.prepend(AccountStatusesFilterMethods) unless ::AccountStatusesFilter <= AccountStatusesFilterMethods
      ::Feed.prepend(FeedMethods) unless ::Feed <= FeedMethods

      @applied = true
    end
  end
end
