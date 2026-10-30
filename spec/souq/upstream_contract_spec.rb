# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'SOUQ upstream contracts', type: :request do
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
