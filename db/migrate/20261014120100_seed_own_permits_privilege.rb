class SeedOwnPermitsPrivilege < ActiveRecord::Migration[8.1]
  KEYS = %w[parking.own_permits].freeze

  def up
    Privilege.seed_defaults!
  end

  def down
    Privilege.where(key: KEYS).destroy_all
  end
end
