# frozen_string_literal: true

module Souq
  # Single, reload-safe entry point that extends Mastodon's Status for SOUQ.
  #
  # It is called from config/initializers/souq.rb inside a `to_prepare` block
  # and stays idempotent so that code reloading in development (which re-runs
  # `to_prepare`) never adds the same attribute twice.
  module StatusExtension
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

      @applied = true
    end
  end
end
