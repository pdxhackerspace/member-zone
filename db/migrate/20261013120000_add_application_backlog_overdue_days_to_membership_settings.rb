class AddApplicationBacklogOverdueDaysToMembershipSettings < ActiveRecord::Migration[8.1]
  # The admin dashboard's application backlog bar splits open applications into those still
  # within this many days of submission and those past it.
  def change
    add_column :membership_settings, :application_backlog_overdue_days, :integer, null: false, default: 7
  end
end
