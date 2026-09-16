class AddPaymentOverdueReminderGraceDays < ActiveRecord::Migration[8.1]
  def change
    add_column :membership_settings, :payment_overdue_reminder_grace_days, :integer, null: false, default: 5
  end
end
