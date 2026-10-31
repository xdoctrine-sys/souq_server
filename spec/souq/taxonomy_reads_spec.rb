# frozen_string_literal: true

require 'rails_helper'
require_relative 'support/taxonomy'
require_relative 'support/taxonomy_cache'

# The taxonomy version must be read once per render, not once per listing
# field. Souq::Current lives exactly one request or one job, so a request and
# an in-process loop have the same budget: one GET of souq:taxonomy:version.
RSpec.describe 'SOUQ taxonomy reads', type: :request do
  include_context 'with API authentication', oauth_scopes: 'read read:statuses'

  let(:version) { 7 }
  let!(:vehicles) { Fabricate(:souq_category, code: 'vehicles', name_en: 'Vehicles', name_ar: 'مركبات') }
  let!(:cars) { Fabricate(:souq_category, code: 'cars', name_en: 'Cars', name_ar: 'سيارات', parent: vehicles) }
  let!(:qatar) { Fabricate(:souq_location, code: 'qatar', name_en: 'Qatar', name_ar: 'قطر', kind: 'region') }
  let!(:doha) { Fabricate(:souq_location, code: 'doha', name_en: 'Doha', name_ar: 'الدوحة', kind: 'city', parent: qatar) }

  before do
    write_taxonomy_version(version)
    Souq::TaxonomyCache.reset!
  end

  def publish(account, text)
    PostStatusService.new.call(account, text: text, visibility: :public)
  end

  def attach_listing(status, category:, location:)
    Fabricate(
      :souq_listing,
      status: status,
      account: status.account,
      category: category,
      category_code: category.code,
      location: location,
      title: 'Item',
      price_mode: 'fixed',
      price_minor: 1000,
      currency: 'QAR'
    )
  end

  it 'reads the version key once for a public timeline of 20 varied listings', :inline_jobs do
    20.times do |index|
      status = publish(Fabricate(:account), "Listing #{index}")
      attach_listing(status, category: index.even? ? cars : vehicles, location: index.even? ? doha : qatar)
    end

    reads = count_taxonomy_version_reads { get '/api/v1/timelines/public', headers: headers }

    expect(response).to have_http_status(200)
    expect(reads).to eq(1)
  end

  it 'reads the version key once when rendering one status for streaming' do
    status = publish(user.account, 'Streamed listing')
    attach_listing(status, category: cars, location: doha)

    reads = count_taxonomy_version_reads { InlineRenderer.render(status, nil, :status) }

    expect(reads).to eq(1)
  end

  it 'reads the version key once for 20 serializations inside one Souq::Current' do
    listings = Array.new(20) do |index|
      status = publish(user.account, "Listing #{index}")
      attach_listing(status, category: index.even? ? cars : vehicles, location: index.even? ? doha : qatar)
    end

    reads = count_taxonomy_version_reads do
      listings.each { |listing| Souq::REST::ListingSerializer.new(listing).as_json }
    end

    expect(reads).to eq(1)
  end
end
