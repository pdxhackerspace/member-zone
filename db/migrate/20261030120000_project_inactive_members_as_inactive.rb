# membership_status is rewritten on save, so rows nobody has touched since the projection
# changed still read 'paying'.
class ProjectInactiveMembersAsInactive < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE users SET membership_status = 'inactive' WHERE membership_state = 'inactive_member'"
  end

  def down
    execute "UPDATE users SET membership_status = 'paying' WHERE membership_state = 'inactive_member'"
  end
end
