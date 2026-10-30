# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'SOUQ upstream contracts', type: :request do
  describe 'filter representations' do
    include_context 'with API authentication', oauth_scopes: 'read:filters'

    let!(:rule) { Fabricate(:custom_filter, account: user.account, title: 'Contract', context: ['home'], action: :hide) }
    let!(:keyword) { Fabricate(:custom_filter_keyword, custom_filter: rule, keyword: 'contract', whole_word: true) }

    it 'preserves the authenticated Mastodon v1 filters representation' do
      get '/api/v1/filters', headers: headers
      expect(response).to have_http_status(200)
      expect(response.parsed_body).to contain_exactly(
        'id' => keyword.id.to_s, 'phrase' => 'contract', 'context' => ['home'],
        'whole_word' => true, 'expires_at' => nil, 'irreversible' => true
      )
    end

    it 'preserves the authenticated Mastodon v2 filters representation' do
      get '/api/v2/filters', headers: headers
      expect(response).to have_http_status(200)
      expect(response.parsed_body).to contain_exactly(
        'id' => rule.id.to_s, 'title' => 'Contract', 'context' => ['home'],
        'expires_at' => nil, 'filter_action' => 'hide', 'statuses' => [],
        'keywords' => [{ 'id' => keyword.id.to_s, 'keyword' => 'contract', 'whole_word' => true }]
      )
    end
  end

  describe 'Status extension contract' do
    # Resolve the parent first: resolving ShallowStatusSerializer on its own
    # triggers a circular load (StatusSerializer -> QuoteSerializer ->
    # ShallowStatusSerializer) and raises a NameError when CI is not set.
    let(:serializers) { [REST::StatusSerializer, REST::ShallowStatusSerializer] }

    it 'snapshots Status::CACHEABLE_ASSOCIATIONS so an upstream change fails loudly' do
      expect(Status::CACHEABLE_ASSOCIATIONS).to eq(
        [
          :application,
          :conversation,
          :media_attachments,
          :preloadable_poll,
          :status_stat,
          :tags,
          {
            account: [:account_stat, { user: :role }],
            active_mentions: :account,
            tagged_objects: :object,
            preview_cards_status: { preview_card: { author_account: [:account_stat, { user: :role }] } },
            quote: { status: { account: [:account_stat, { user: :role }] } },
          },
        ]
      )
    end

    it 'exposes the souq_listing attribute on both status serializers' do
      expect(serializers.map { |serializer| serializer._attributes_data.key?(:souq_listing) }).to eq([true, true])
    end

    it 'is idempotent and keeps the same attributes after several calls' do
      before_keys = serializers.index_with { |serializer| serializer._attributes_data.keys }

      2.times { Souq::StatusExtension.apply! }

      expect(serializers.index_with { |serializer| serializer._attributes_data.keys }).to eq(before_keys)
    end
  end
end
