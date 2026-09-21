class AddCadenceToReminderSettings < ActiveRecord::Migration[8.1]
  # Where the per-reminder cadence now lives. The offsets and intervals are copied out of
  # membership_settings rather than reset to catalog defaults, so an admin who tuned any of
  # them keeps their tuning; the columns they came from are dropped in a later migration.
  #
  # +from+ names the membership_settings column a value used to come from, +default+ the value
  # to fall back on when it was never configurable or the settings row does not exist yet.
  CADENCE = {
    'slack_signup' => {
      offset: { from: 'slack_signup_reminder_initial_delay_days', default: 7 },
      interval: { from: 'slack_signup_reminder_repeat_delay_days', default: 14 },
      max: nil
    },
    'application_link' => {
      offset: { from: 'application_link_reminder_delay_days', default: 3 },
      interval: { from: 'application_link_reminder_delay_days', default: 3 },
      max: { from: 'application_link_reminder_max_count', default: 3 }
    },
    'payment_overdue' => {
      offset: { from: 'payment_overdue_reminder_grace_days', default: 5 },
      interval: { from: 'payment_overdue_reminder_repeat_days', default: 7 },
      max: nil
    },
    'orientation' => {
      offset: { from: 'orientation_reminder_repeat_days', default: 14 },
      interval: { from: 'orientation_reminder_repeat_days', default: 14 },
      max: nil
    },
    # Negated: the first parking reminder goes out before the notice expires, and the setting
    # it comes from counted days before expiration as a positive number.
    'parking_notices' => {
      offset: { from: 'parking_notice_reminder_days_before_expiration', default: 3, negate: true },
      interval: { from: 'parking_notice_expired_reminder_repeat_days', default: 7 },
      max: { default: 4 }
    },
    'lapsed_access' => {
      offset: { default: 0 },
      interval: { default: 1 },
      max: nil
    },
    'staff_application' => {
      offset: { default: 7 },
      interval: { default: 3 },
      max: nil
    }
  }.freeze

  STAFF_APPLICATION_DESCRIPTION = 'Reminder to directors that a membership application has been waiting for ' \
                                  'review. Sent to reviewers rather than to the applicant.'.freeze

  def up
    add_column :reminder_settings, :start_offset_days, :integer, null: false, default: 0
    add_column :reminder_settings, :interval_days, :integer, null: false, default: 7
    add_column :reminder_settings, :max_reminders, :integer

    seed_staff_application_reminder
    CADENCE.each { |key, cadence| apply_cadence(key, cadence) }
  end

  def down
    remove_column :reminder_settings, :start_offset_days
    remove_column :reminder_settings, :interval_days
    remove_column :reminder_settings, :max_reminders
  end

  private

  # The staff reminder ran on hardcoded constants and had no settings row of its own. It is
  # created enabled because that is how it has always behaved.
  def seed_staff_application_reminder
    execute(<<~SQL.squish)
      INSERT INTO reminder_settings (key, name, description, enabled, allow_opt_out, lookback_days,
                                     created_at, updated_at)
      VALUES ('staff_application', 'Stale application reminder',
              #{quote(STAFF_APPLICATION_DESCRIPTION)}, TRUE, FALSE, 1, NOW(), NOW())
      ON CONFLICT (key) DO NOTHING
    SQL
  end

  def apply_cadence(key, cadence)
    execute(<<~SQL.squish)
      UPDATE reminder_settings SET
        start_offset_days = #{value_expression(cadence[:offset])},
        interval_days = #{value_expression(cadence[:interval])},
        max_reminders = #{cadence[:max] ? value_expression(cadence[:max]) : 'NULL'},
        updated_at = NOW()
      WHERE key = #{quote(key)}
    SQL
  end

  def value_expression(spec)
    negate = spec[:negate] ? '-1 * ' : ''
    column = spec[:from]
    return "#{negate}#{spec[:default]}" if column.blank?

    "#{negate}COALESCE((SELECT #{column} FROM membership_settings ORDER BY id LIMIT 1), #{spec[:default]})"
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
