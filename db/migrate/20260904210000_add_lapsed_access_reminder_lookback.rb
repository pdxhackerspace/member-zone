class AddLapsedAccessReminderLookback < ActiveRecord::Migration[8.1]
  def up
    add_column :reminder_settings, :lookback_days, :integer, default: 1, null: false

    add_column :access_logs, :lapsed_access_reminder_sent_at, :datetime
    add_index :access_logs, %i[user_id logged_at],
              where: 'lapsed_access_reminder_sent_at IS NULL',
              name: 'index_access_logs_unnotified_lapsed_access'

    backfill_already_notified_access_logs
  end

  def down
    remove_index :access_logs, name: 'index_access_logs_unnotified_lapsed_access'
    remove_column :access_logs, :lapsed_access_reminder_sent_at
    remove_column :reminder_settings, :lookback_days
  end

  private

  # Members who were already reminded must not be re-reminded for the visits that reminder
  # covered, so stamp every entry logged at or before their last reminder.
  def backfill_already_notified_access_logs
    execute(<<~SQL.squish)
      UPDATE access_logs
      SET lapsed_access_reminder_sent_at = users.lapsed_access_reminder_sent_at,
          updated_at = NOW()
      FROM users
      WHERE access_logs.user_id = users.id
        AND users.lapsed_access_reminder_sent_at IS NOT NULL
        AND access_logs.logged_at IS NOT NULL
        AND access_logs.logged_at <= users.lapsed_access_reminder_sent_at
    SQL
  end
end
