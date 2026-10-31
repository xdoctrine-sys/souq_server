# frozen_string_literal: true

# SOUQ listings API (design section 6.2).
#
# Every write goes through the SOUQ services, which are the validation boundary:
# the request halves (`status`, `listing`) are handed over as plain hashes and
# `Souq::Listings::Input` collects the problems keyed by the request field names.
# The response is always the full Mastodon status, with `souq_listing` inlined
# by Souq::StatusExtension, so a client can insert it straight into its timeline.
class Souq::Api::V1::ListingsController < Api::BaseController
  include Authorization

  before_action -> { authorize_if_got_token! :read, :'read:statuses' }, only: [:show]
  before_action -> { doorkeeper_authorize! :write, :'write:statuses' }, only: [:create, :update, :state]
  before_action :require_user!, only: [:create, :update, :state]
  before_action :set_listing, only: [:show]
  before_action :set_owned_listing, only: [:update, :state]

  override_rate_limit_headers :create, family: :statuses
  override_rate_limit_headers :update, family: :statuses

  rescue_from Souq::Listings::ValidationError, with: :render_listing_error

  def show
    cache_if_unauthenticated!
    @status = preload_collection([@listing.status], Status).first

    render json: @status, serializer: REST::StatusSerializer
  end

  def create
    @status = Souq::Listings::Create.call(
      current_user.account,
      status: status_params,
      listing: listing_params,
      application: doorkeeper_token&.application,
      idempotency: request.headers['Idempotency-Key']
    )

    render json: @status, serializer: REST::StatusSerializer
  end

  def update
    @listing = Souq::Listings::Update.call(@listing, status_params: status_params, listing_params: listing_params)

    render json: @listing.status, serializer: REST::StatusSerializer
  end

  def state
    @listing = Souq::Listings::ChangeState.call(@listing, params[:state])

    render json: @listing.status, serializer: REST::StatusSerializer
  end

  private

  # Same rules as `GET /api/v1/statuses/:id`: an unknown listing and a listing
  # whose status is not visible answer the very same 404, so the endpoint never
  # leaks whether the listing exists.
  def set_listing
    @listing = Souq::Listing.find(params[:id])
    authorize @listing.status, :show?
  rescue ActiveRecord::RecordNotFound, Mastodon::NotPermittedError
    not_found
  end

  # A status the requester cannot see is answered as a 404, exactly like an
  # unknown id; a status they can see but do not own is a plain 403 (design
  # section 5.3, prompt requirement 7).
  def set_owned_listing
    @listing = Souq::Listing.find(params[:id])
    return not_found unless policy(@listing.status).show?

    authorize @listing.status, :update?
  rescue ActiveRecord::RecordNotFound
    not_found
  end

  # Mirrors Api::V1::StatusesController#status_params, plus the `status` -> `text`
  # rename the SOUQ services use, and accepts a request without a `status` half.
  def status_params
    raw = params[:status]
    raw = ActionController::Parameters.new unless raw.is_a?(ActionController::Parameters)

    raw.permit(
      :status,
      :sensitive,
      :spoiler_text,
      :visibility,
      :language,
      :scheduled_at,
      allowed_mentions: [],
      media_ids: [],
      media_attributes: [:id, :thumbnail, :description, :focus],
      poll: [:multiple, :hide_totals, :expires_in, options: []]
    ).to_h.symbolize_keys.tap do |attributes|
      attributes[:text] = attributes.delete(:status)
    end
  end

  # `to_unsafe_h` is deliberate: it is the only way to see an `attributes` value
  # that was not declared, and rejecting a non-empty `attributes` is part of the
  # contract until T11b. Validation happens in Souq::Listings::Input.
  def listing_params
    raw = params[:listing]

    raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : {}
  end

  def render_listing_error(error)
    render json: { error: error.message, details: error.details }, status: 422
  end
end
