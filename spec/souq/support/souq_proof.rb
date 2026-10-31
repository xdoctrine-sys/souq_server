# frozen_string_literal: true

# Loaded explicitly by the proof spec. Nothing is installed at require time.
module SouqProof
  class Record < ApplicationRecord
    self.table_name = 'souq_proof_records'
  end

  class CreationError < StandardError; end

  class << self
    # Set to true to make the proof callback reject the listing. The real
    # `souq_attach_listing` callback runs first, so the rejection happens after
    # the real Souq::Listing row exists, inside the same transaction.
    attr_accessor :fail_next
  end

  def self.attach(status)
    draft = Souq::Current.listing_draft
    return unless status.local? && draft.present?

    Record.create!(
      status_id: status.id,
      transaction_open: Status.connection.transaction_open?,
      transaction_id: Status.connection.select_value('SELECT txid_current()').to_s
    )
    raise CreationError, 'proof callback rejected listing' if fail_next
  end

  def self.install!
    @callback = ->(status) { SouqProof.attach(status) }
    Status.after_create(@callback)
    # Resolve the parent first, then extend both already-loaded classes explicitly.
    @serializers = [REST::StatusSerializer, REST::ShallowStatusSerializer]
    @attributes = @serializers.index_with { |serializer| serializer._attributes_data.dup }
    @serializers.each do |serializer|
      serializer.attribute :souq_proof, if: -> { SouqProof::Record.exists?(status_id: object.id) } do
        SouqProof::Record.find_by!(status_id: object.id).transaction_open
      end
    end
  end

  def self.uninstall!
    Status.skip_callback(:create, :after, @callback) if @callback
    @attributes&.each { |serializer, attributes| serializer._attributes_data = attributes }
    @callback = @serializers = @attributes = nil
  end

  def self.cleanup!(account)
    ApplicationRecord.transaction do
      Status.unscoped.where(account_id: account.id).destroy_all
      # Conversations have no cascading FK to their parent account or status.
      Conversation.where(parent_account_id: account.id).delete_all
      # Access tokens have no FK to the account, so they are removed explicitly.
      Doorkeeper::AccessToken.where(resource_owner_id: User.where(account_id: account.id).select(:id)).delete_all
      # Associated users, keypairs and statistics are destroyed or cascade by FK.
      account.destroy!
    end
  end
end
