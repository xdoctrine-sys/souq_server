# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'

# Keep this regression alongside the other SOUQ model guards.
RSpec.describe Souq::AuditLog do # rubocop:disable RSpec/SpecFilePathFormat
  it 'keeps the audit when a local admin account is physically deleted' do
    account = Fabricate(:user, role: UserRole.find_by!(name: 'Admin')).account
    account_id = account.id
    audit = Fabricate(:souq_audit_log, account:)
    payload = audit.recorded_changes

    expect { DeleteAccountService.new.call(account, reserve_email: false, reserve_username: false) }.to_not raise_error
    expect(Account.exists?(account_id)).to be(false)
    expect(described_class.exists?(audit.id)).to be(true)
    expect(audit.reload.account_id).to be_nil
    expect(audit.recorded_changes).to eq(payload)
    expect(audit).to be_valid
  end

  it 'refuses creation without an account' do
    audit = Fabricate.build(:souq_audit_log, account: nil)

    expect(audit).to_not be_valid
    expect(audit.errors[:account]).to be_present
    expect { audit.save! }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
