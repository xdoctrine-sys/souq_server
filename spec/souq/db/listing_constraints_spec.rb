# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'

# Exercise SQL checks without model validation.
RSpec.describe 'SOUQ listing database contracts' do # rubocop:disable RSpec/DescribeClass
  let(:connection) { ActiveRecord::Base.connection }
  let(:listing) { Fabricate(:souq_listing) }

  {
    'free with amount' => 'price_mode = 3, currency = NULL',
    'fixed without amount' => 'price_minor = NULL',
    'fixed without currency' => 'currency = NULL',
    'on_request with currency' => 'price_mode = 2, price_minor = NULL',
    'free with monthly period' => 'price_mode = 3, price_minor = NULL, currency = NULL, price_period = 3',
    'zero amount' => 'price_minor = 0',
    'lowercase currency' => "currency = 'qar'",
    'negative amount' => 'price_minor = -1',
    'invalid price mode' => 'price_mode = 5',
    'invalid period' => 'price_period = 5',
    'invalid sale mode' => 'sale_mode = 2',
    'invalid state' => 'state = 5',
    'empty title' => "title = ''",
    'non-object attributes' => "attribute_values = '[]'::jsonb",
  }.each do |description, assignments|
    it "rejects #{description} through direct SQL" do
      id = listing.id
      expect { connection.transaction(requires_new: true) { connection.execute("UPDATE souq_listings SET #{assignments} WHERE id = #{id}") } }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::CheckViolation/)
      expect(listing.reload.price_minor).to eq(1250)
    end
  end

  it 'has the exact expected indexes, sorting and price predicate' do
    indexes = connection.indexes('souq_listings').index_by(&:name)
    expect(indexes.keys).to match_array(%w(index_souq_listings_on_status_id index_souq_listings_category_recent index_souq_listings_category_price index_souq_listings_account_recent index_souq_listings_on_location_id index_souq_listings_on_attribute_values))
    expect(indexes.fetch('index_souq_listings_on_status_id').columns).to eq(['status_id'])
    expect(indexes.fetch('index_souq_listings_on_status_id').unique).to be(true)
    recent = indexes.fetch('index_souq_listings_category_recent')
    expect(recent.columns).to eq(%w(category_id state published_at))
    expect(recent.orders).to eq('published_at' => :desc)
    price = indexes.fetch('index_souq_listings_category_price')
    expect(price.columns).to eq(%w(category_id state price_minor status_id))
    expect(price.where).to eq('(price_minor IS NOT NULL)')
    account = indexes.fetch('index_souq_listings_account_recent')
    expect(account.columns).to eq(%w(account_id published_at))
    expect(account.orders).to eq('published_at' => :desc)
    expect(indexes.fetch('index_souq_listings_on_location_id').columns).to eq(['location_id'])
  end

  it 'has a GIN attribute index with jsonb_path_ops' do
    gin = connection.indexes('souq_listings').find { |index| index.name == 'index_souq_listings_on_attribute_values' }
    expect(gin.columns).to eq(['attribute_values'])
    expect(gin.using).to eq(:gin)
    expect(gin.opclasses).to eq(:jsonb_path_ops)
    definition = connection.select_value("SELECT pg_get_indexdef('index_souq_listings_on_attribute_values'::regclass)")
    expect(definition).to match(/USING gin \(attribute_values jsonb_path_ops\)\z/)
  end

  it 'keeps the categories SQL byte-identical and refuses unknown table names' do
    expect(Souq::DbObjects.tree_sql('souq_categories')).to eq(Souq::DbObjects::SQL)
    expect(Souq::DbObjects.tree_sql('souq_locations')).to_not match(/categor/i)
    expect { Souq::DbObjects.tree_sql('statuses') }.to raise_error(KeyError)
  end
end
