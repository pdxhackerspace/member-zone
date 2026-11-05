# Whether announcers may announce members whose membership doesn't currently grant access (for
# example one wrongly left inactive). Off by default: only members with access are announced.
class AddAnnounceInactiveMembersToDefaultSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :default_settings, :announce_inactive_members, :boolean, default: false, null: false
  end
end
