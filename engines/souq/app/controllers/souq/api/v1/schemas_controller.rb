# frozen_string_literal: true

# Public, read-only effective attribute schema of a category (design section
# 6.1, prompt requirement 4). It reads the in-memory taxonomy snapshot, so the
# number of SQL queries does not depend on the size of the tree or on the number
# of attributes. The response is cacheable and carries an ETag built on the
# taxonomy version and the category code, so a client sending If-None-Match
# gets a 304.
class Souq::Api::V1::SchemasController < Api::BaseController
  def show
    snapshot = Souq::TaxonomyCache.snapshot
    category = snapshot.category(params[:code])

    return render_category_not_found if category.nil? || !category[:active]

    schema = snapshot.schema(category[:code])
    return render_schema_unavailable if schema.nil? || schema.invalid?

    expires_in(15.seconds, public: true, stale_while_revalidate: 30.seconds, stale_if_error: 1.day)

    return unless stale?(etag: [snapshot.version, category[:code]], public: true)

    render json: envelope(category, snapshot.version, schema), serializer: Souq::REST::SchemaSerializer
  end

  private

  def envelope(category, version, schema)
    Souq::Schema::Envelope.new(category: category, taxonomy_version: version, attributes: schema.attributes)
  end

  def render_category_not_found
    render json: { error: 'Record not found' }, status: 404
  end

  def render_schema_unavailable
    render json: { error: 'The attribute schema is unavailable' }, status: 503
  end
end
