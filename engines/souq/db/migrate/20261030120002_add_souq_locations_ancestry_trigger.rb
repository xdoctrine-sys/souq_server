# frozen_string_literal: true

class AddSouqLocationsAncestryTrigger < ActiveRecord::Migration[8.1]
  def up
    safety_assured { Souq::DbObjects.install!(connection, table: 'souq_locations') }
  end

  def down
    safety_assured { Souq::DbObjects.uninstall!(connection, table: 'souq_locations') }
  end
end
