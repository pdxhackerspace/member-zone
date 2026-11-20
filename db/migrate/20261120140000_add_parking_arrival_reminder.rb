# Arrival reminders are paced in minutes, like announcers, rather than in days.
# Existing databases learn about the column, the template, and the reminder row here.
# Fresh databases get the template and the row from db:seed.
class AddParkingArrivalReminder < ActiveRecord::Migration[8.1]
  def up
    add_column :reminder_settings, :repeat_after_minutes, :integer, null: false, default: 120

    EmailTemplate.seed_defaults!
    ReminderSetting.seed_defaults!
  end

  def down
    EmailTemplate.where(key: 'parking_arrival_reminder').delete_all
    ReminderSetting.where(key: 'parking_arrival').delete_all
    remove_column :reminder_settings, :repeat_after_minutes
  end
end
