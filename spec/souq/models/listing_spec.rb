# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'

RSpec.describe Souq::Listing do # rubocop:disable RSpec/SpecFilePathFormat
  let(:listing) { Fabricate(:souq_listing) }

  it 'accepts a local listing with empty attributes and matching account' do
    expect(listing).to be_valid
    expect(listing.attribute_values).to eq({})
    expect(listing.account_id).to eq(listing.status.account_id)
  end

  it 'refuses nonempty attributes and non-object values' do
    [{ 'brand' => 'toyota' }, [], nil].each do |value|
      listing.attribute_values = value
      expect(listing).to_not be_valid
      expect(listing.errors[:attribute_values]).to be_present
    end
  end

  it 'refuses an inactive or non-listable category on local creation' do
    category = Fabricate(:souq_category)
    candidate = Fabricate.build(:souq_listing, category:)
    category.active = false
    expect(candidate).to_not be_valid
    category.active = true
    category.listable = false
    expect(candidate).to_not be_valid
  end

  it 'preserves existing listings when their category is deactivated' do
    listing.category.update!(active: false)
    expect(listing).to be_valid
  end

  it 'requires a matching category code on local creation' do
    candidate = Fabricate.build(:souq_listing, category_code: 'unknown')
    expect(candidate).to_not be_valid
    expect(candidate.errors[:category_code]).to be_present
  end

  it 'refuses a listing with another account' do
    listing.account = Fabricate(:account)
    expect(listing).to_not be_valid
    expect(listing.errors[:account]).to be_present
  end

  it 'refuses private and direct statuses but accepts unlisted' do
    %w(private direct).each do |visibility|
      listing.status.visibility = visibility
      expect(listing).to_not be_valid
    end
    listing.status.visibility = 'unlisted'
    expect(listing).to be_valid
  end

  it 'refuses a remote status, a reblog and a mismatched local flag' do
    listing.status.uri = 'https://remote.example/status/1'
    listing.status.local = false
    expect(listing).to_not be_valid
    listing.status.uri = nil
    listing.status.local = true
    listing.status.reblog = Fabricate(:status)
    expect(listing).to_not be_valid
    listing.status.reblog = nil
    listing.local = false
    expect(listing).to_not be_valid
  end

  it 'validates title, enums, price, period and configured currency' do
    [
      { title: '' }, { title: 'x' * 141 }, { price_mode: 9 },
      { price_period: 9 }, { sale_mode: 9 }, { state: 9 },
      { price_minor: 0 }, { price_minor: nil }, { currency: nil },
      { currency: 'qar' }, { currency: 'USD' },
      { price_mode: 'free' }, { price_mode: 'on_request' },
      { price_mode: 'none', price_minor: nil, currency: nil, price_period: 'month' }
    ].each do |attributes|
      candidate = Fabricate.build(:souq_listing, **attributes)
      expect(candidate).to_not be_valid
    end
  end

  it 'accepts all supported price modes with coherent values' do
    %w(fixed negotiable).each do |mode|
      expect(Fabricate.build(:souq_listing, price_mode: mode, price_period: 'month')).to be_valid
    end
    %w(free on_request none).each do |mode|
      expect(Fabricate.build(:souq_listing, price_mode: mode, price_minor: nil, currency: nil)).to be_valid
    end
  end

  it 'cascades on physical Status#destroy!' do
    id = listing.id
    listing.status.destroy!
    expect(described_class.exists?(id)).to be(false)
  end

  it 'cascades on direct SQL DELETE of a status' do
    id = listing.id
    described_class.connection.execute("DELETE FROM statuses WHERE id = #{listing.status_id}")
    expect(described_class.exists?(id)).to be(false)
  end

  it 'cascades on a real physical local account deletion' do
    account = Fabricate(:user).account
    status = Fabricate(:status, account:)
    record = Fabricate(:souq_listing, status:)
    expect { DeleteAccountService.new.call(account, reserve_email: false, reserve_username: false) }.to_not raise_error
    expect(Account.exists?(account.id)).to be(false)
    expect(described_class.exists?(record.id)).to be(false)
  end

  it 'restricts deletion of a referenced category and location' do
    location = Fabricate(:souq_location)
    listing.update!(location:)
    connection = described_class.connection
    expect { connection.transaction(requires_new: true) { connection.execute("DELETE FROM souq_categories WHERE id = #{listing.category_id}") } }
      .to raise_error(ActiveRecord::InvalidForeignKey)
    expect { connection.transaction(requires_new: true) { connection.execute("DELETE FROM souq_locations WHERE id = #{location.id}") } }
      .to raise_error(ActiveRecord::InvalidForeignKey)
    expect(listing.reload).to be_persisted
  end
end
