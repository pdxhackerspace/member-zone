class AddOrientationReminder < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:membership_settings, :orientation_reminder_repeat_days)
      add_column :membership_settings, :orientation_reminder_repeat_days, :integer, null: false, default: 14
    end

    unless column_exists?(:users, :orientation_reminder_sent_at)
      add_column :users, :orientation_reminder_sent_at, :datetime
      add_index :users, :orientation_reminder_sent_at
    end

    seed_reminder_setting
    seed_email_template
  end

  def down
    execute("DELETE FROM email_templates WHERE key = 'orientation_reminder'")
    execute("DELETE FROM reminder_settings WHERE key = 'orientation'")

    if column_exists?(:users, :orientation_reminder_sent_at)
      remove_index :users, :orientation_reminder_sent_at, if_exists: true
      remove_column :users, :orientation_reminder_sent_at
    end

    return unless column_exists?(:membership_settings, :orientation_reminder_repeat_days)

    remove_column :membership_settings, :orientation_reminder_repeat_days
  end

  private

  # Seeded with literal values rather than through ReminderSetting::CATALOG and
  # EmailTemplate::DEFAULT_TEMPLATES: a migration has to keep working against the models as
  # they are years from now, and constants get renamed and rewritten.
  def seed_reminder_setting
    execute(<<~SQL.squish)
      INSERT INTO reminder_settings (key, name, description, enabled, created_at, updated_at)
      VALUES (
        'orientation',
        'Orientation reminder',
        'Reminder to approved members who have not had their building access orientation yet.',
        FALSE,
        NOW(),
        NOW()
      )
      ON CONFLICT (key) DO NOTHING
    SQL
  end

  def seed_email_template
    execute(<<~SQL)
      INSERT INTO email_templates
        (key, name, description, subject, body_html, body_text, enabled, needs_review, send_immediately,
         created_at, updated_at)
      VALUES (
        'orientation_reminder',
        'Orientation Reminder',
        'Reminder to approved members who have not had their building access orientation yet',
        '{{organization_name}}: Book your building access orientation',
        #{connection.quote(template_body_html)},
        #{connection.quote(template_body_text)},
        TRUE,
        TRUE,
        FALSE,
        NOW(),
        NOW()
      )
      ON CONFLICT (key) DO NOTHING
    SQL
  end

  def template_body_html
    <<~HTML
      <p>Hi {{member_name}},</p>
      <p>Welcome to {{organization_name}}! Your membership was approved {{days_since_approval}} days ago, but we have not recorded your building access orientation yet.</p>
      <p>Orientation is a short walkthrough covering how to get in, how to stay safe, and how the space works. We cannot issue you a key until you have done it, so it is the one thing standing between you and the shop.</p>
      <p>Reply to this email and we will find you a time.</p>
      <p>See you soon,<br>The {{organization_name}} Team</p>
    HTML
  end

  def template_body_text
    <<~TEXT
      Hi {{member_name}},

      Welcome to {{organization_name}}! Your membership was approved {{days_since_approval}} days ago, but we have not recorded your building access orientation yet.

      Orientation is a short walkthrough covering how to get in, how to stay safe, and how the space works. We cannot issue you a key until you have done it, so it is the one thing standing between you and the shop.

      Reply to this email and we will find you a time.

      See you soon,
      The {{organization_name}} Team
    TEXT
  end
end
