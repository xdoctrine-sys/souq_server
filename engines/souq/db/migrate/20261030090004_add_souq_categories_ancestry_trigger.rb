# frozen_string_literal: true

class AddSouqCategoriesAncestryTrigger < ActiveRecord::Migration[8.1]
  def up
    safety_assured { Souq::DbObjects.install!(connection) }
  end

  def down
    safety_assured { Souq::DbObjects.uninstall!(connection) }
  end
end
