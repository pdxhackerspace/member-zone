class HoldReminderTemplatesInMailQueue < ActiveRecord::Migration[8.1]
  REMINDER_TEMPLATE_KEYS = %w[
    slack_signup_reminder
    slack_signup_nag
    application_link_reminder
    payment_past_due
    orientation_reminder
    lapsed_access_reminder
    parking_permit_expiring_soon
    parking_ticket_expiring_soon
    parking_permit_expired
    parking_ticket_expired
    parking_permit_overdue_reminder
    parking_ticket_overdue_reminder
    parking_permit_final_reminder
    parking_ticket_final_reminder
  ].freeze

  def up
    REMINDER_TEMPLATE_KEYS.each do |key|
      execute(<<~SQL.squish)
        UPDATE email_templates
        SET send_immediately = FALSE, updated_at = NOW()
        WHERE key = #{connection.quote(key)}
      SQL
    end
  end

  def down
    execute(<<~SQL.squish)
      UPDATE email_templates
      SET send_immediately = TRUE, updated_at = NOW()
      WHERE key IN (#{REMINDER_TEMPLATE_KEYS.map { |key| connection.quote(key) }.join(', ')})
        AND key IN ('slack_signup_reminder', 'slack_signup_nag')
    SQL
  end
end
