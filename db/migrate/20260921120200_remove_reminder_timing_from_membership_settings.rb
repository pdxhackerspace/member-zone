class RemoveReminderTimingFromMembershipSettings < ActiveRecord::Migration[8.1]
  # Reminder timing lives on reminder_settings now. AddCadenceToReminderSettings copied these
  # values across first, so this only removes the columns they came from.
  #
  # payment_grace_period_days is unrelated to reminders and goes with them because it was never
  # wired to anything: the form offered it as "days before membership is marked as lapsed", but
  # that transition has always read overdue_grace_period_days.
  REMOVED = {
    slack_signup_reminder_initial_delay_days: 7,
    slack_signup_reminder_repeat_delay_days: 14,
    application_link_reminder_delay_days: 3,
    application_link_reminder_max_count: 3,
    payment_overdue_reminder_grace_days: 5,
    payment_overdue_reminder_repeat_days: 7,
    orientation_reminder_repeat_days: 14,
    parking_notice_reminder_days_before_expiration: 3,
    parking_notice_expired_reminder_repeat_days: 7,
    parking_notice_final_reminder_days_after_expiration: 14,
    payment_grace_period_days: 14
  }.freeze

  def up
    REMOVED.each_key { |column| remove_column :membership_settings, column }
  end

  def down
    REMOVED.each do |column, default|
      add_column :membership_settings, column, :integer, null: false, default: default
    end
  end
end
