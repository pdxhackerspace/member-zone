# Tells a member's first pass through the profile setup wizard apart from a later edit. Everyone
# already here is treated as having finished it: they reach the wizard from "Update your profile".
class AddProfileSetupCompletedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :profile_setup_completed_at, :datetime

    reversible do |dir|
      dir.up { execute 'UPDATE users SET profile_setup_completed_at = created_at' }
    end
  end
end
