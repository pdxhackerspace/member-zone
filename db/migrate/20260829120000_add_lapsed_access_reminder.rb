class AddLapsedAccessReminder < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:users, :lapsed_access_reminder_sent_at)
      add_column :users, :lapsed_access_reminder_sent_at, :datetime
      add_index :users, :lapsed_access_reminder_sent_at
    end

    seed_reminder_setting
    seed_email_template
  end

  def down
    execute("DELETE FROM email_templates WHERE key = 'lapsed_access_reminder'")
    execute("DELETE FROM reminder_settings WHERE key = 'lapsed_access'")

    if column_exists?(:users, :lapsed_access_reminder_sent_at)
      remove_index :users, :lapsed_access_reminder_sent_at, if_exists: true
      remove_column :users, :lapsed_access_reminder_sent_at
    end
  end

  private

  def seed_reminder_setting
    execute(<<~SQL.squish)
      INSERT INTO reminder_settings (key, name, description, enabled, allow_opt_out, created_at, updated_at)
      VALUES (
        'lapsed_access',
        'Lapsed member access reminder',
        'Daily reminder to inactive members who badged in yesterday that their membership has lapsed and how to reactivate.',
        FALSE,
        TRUE,
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
        'lapsed_access_reminder',
        'Lapsed Member Access Reminder',
        'Sent when an inactive member badged in yesterday',
        #{connection.quote(template_subject)},
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

  def template_subject
    '{{organization_name}}: Your membership has lapsed'
  end

  def template_body_html
    <<~HTML
      <h1>Membership lapsed</h1>
      <p>Hello {{member_name}},</p>
      <p>Our access logs show you used {{organization_name}} facilities yesterday, but your membership lapsed on {{lapsed_at}}.</p>
      <p>{{reactivation_guidance_html}}</p>
      <p>Visit your <a href="{{profile_url}}">member profile</a> for reactivation options, or email <a href="mailto:{{support_email}}">{{support_email}}</a> if you need help.</p>
      <p>Best regards,<br>The {{organization_name}} Team</p>
    HTML
  end

  def template_body_text
    <<~TEXT
      Membership lapsed

      Hello {{member_name}},

      Our access logs show you used {{organization_name}} facilities yesterday, but your membership lapsed on {{lapsed_at}}.

      {{reactivation_guidance_text}}

      Visit your member profile for reactivation options: {{profile_url}}
      Or email {{support_email}} if you need help.

      Best regards,
      The {{organization_name}} Team
    TEXT
  end
end
