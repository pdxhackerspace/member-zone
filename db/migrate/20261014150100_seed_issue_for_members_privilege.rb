class SeedIssueForMembersPrivilege < ActiveRecord::Migration[8.1]
  def up
    Privilege.seed_defaults!
  end

  def down
    Privilege.where(key: 'parking.issue_for_members').destroy_all
  end
end
