class AddParkingNoticeReminders < ActiveRecord::Migration[8.1]
  def up
    change_table :membership_settings, bulk: true do |t|
      t.integer :parking_notice_reminder_days_before_expiration, null: false, default: 3
      t.integer :parking_notice_expired_reminder_repeat_days, null: false, default: 7
      t.integer :parking_notice_final_reminder_days_after_expiration, null: false, default: 14
    end

    change_table :parking_notices, bulk: true do |t|
      t.datetime :pre_expiration_reminder_sent_at
      t.datetime :expiration_notice_sent_at
      t.datetime :overdue_reminder_sent_at
      t.datetime :final_reminder_sent_at
    end

    add_index :parking_notices, :pre_expiration_reminder_sent_at
    add_index :parking_notices, :expiration_notice_sent_at

    execute <<~SQL.squish
      INSERT INTO reminder_settings (key, name, description, enabled, created_at, updated_at)
      VALUES (
        'parking_notices',
        'Parking notice reminders',
        'Pre-expiration, expiration, and follow-up reminders for parking permits and tickets. The initial issued email on creation is always sent.',
        false,
        NOW(),
        NOW()
      )
      ON CONFLICT (key) DO NOTHING
    SQL

    parking_reminder_templates.each do |attrs|
      next if EmailTemplate.exists?(key: attrs[:key])

      EmailTemplate.create!(attrs.merge(enabled: true, needs_review: true))
    end
  end

  def down
    EmailTemplate.where(
      key: %w[
        parking_permit_expiring_soon parking_ticket_expiring_soon
        parking_permit_overdue_reminder parking_ticket_overdue_reminder
        parking_permit_final_reminder parking_ticket_final_reminder
      ]
    ).delete_all

    execute "DELETE FROM reminder_settings WHERE key = 'parking_notices'"

    change_table :parking_notices, bulk: true do |t|
      t.remove :pre_expiration_reminder_sent_at,
               :expiration_notice_sent_at,
               :overdue_reminder_sent_at,
               :final_reminder_sent_at
    end

    change_table :membership_settings, bulk: true do |t|
      t.remove :parking_notice_reminder_days_before_expiration,
               :parking_notice_expired_reminder_repeat_days,
               :parking_notice_final_reminder_days_after_expiration
    end
  end

  private

  def parking_reminder_templates
    [
      expiring_soon_template('permit'),
      expiring_soon_template('ticket'),
      overdue_reminder_template('permit'),
      overdue_reminder_template('ticket'),
      final_reminder_template('permit'),
      final_reminder_template('ticket')
    ]
  end

  def expiring_soon_template(kind)
    label = kind == 'permit' ? 'Permit' : 'Ticket'
    deadline = kind == 'permit' ? 'expires' : 'deadline'
    {
      key: "parking_#{kind}_expiring_soon",
      name: "Parking #{label} Expiring Soon",
      description: "Reminder before a parking #{kind} #{deadline}.",
      subject: "{{organization_name}}: Parking #{label} Expiring Soon",
      body_html: <<~HTML,
        <p>Hi {{member_name}},</p>
        <p>Your parking #{kind} for the project at <strong>{{location}}</strong> #{deadline} on <strong>{{expires_at}}</strong>.</p>
        <p><strong>Description:</strong> {{description}}</p>
        <p>Please remove or renew your project before then.</p>
      HTML
      body_text: <<~TEXT
        Hi {{member_name}},

        Your parking #{kind} for the project at {{location}} #{deadline} on {{expires_at}}.

        Description: {{description}}

        Please remove or renew your project before then.
      TEXT
    }
  end

  def overdue_reminder_template(kind)
    label = kind == 'permit' ? 'Permit' : 'Ticket'
    {
      key: "parking_#{kind}_overdue_reminder",
      name: "Parking #{label} Overdue Reminder",
      description: "Repeat reminder after a parking #{kind} has expired.",
      subject: "{{organization_name}}: Parking #{label} Still Needs Attention",
      body_html: <<~HTML,
        <p>Hi {{member_name}},</p>
        <p>Your parking #{kind} for the project at <strong>{{location}}</strong> expired on {{expires_at}} and still needs attention.</p>
        <p><strong>Description:</strong> {{description}}</p>
        <p>Please remove or address the project as soon as possible.</p>
      HTML
      body_text: <<~TEXT
        Hi {{member_name}},

        Your parking #{kind} for the project at {{location}} expired on {{expires_at}} and still needs attention.

        Description: {{description}}

        Please remove or address the project as soon as possible.
      TEXT
    }
  end

  def final_reminder_template(kind)
    label = kind == 'permit' ? 'Permit' : 'Ticket'
    {
      key: "parking_#{kind}_final_reminder",
      name: "Parking #{label} Final Reminder",
      description: "Final warning before unattended parking #{kind} items may be disposed of.",
      subject: "{{organization_name}}: Final Parking #{label} Reminder",
      body_html: <<~HTML,
        <p>Hi {{member_name}},</p>
        <p>This is a final reminder about the parking #{kind} for the project at <strong>{{location}}</strong>, which expired on {{expires_at}}.</p>
        <p><strong>Description:</strong> {{description}}</p>
        <p><strong>If the project is not removed promptly, your belongings may be disposed of.</strong></p>
        <p>Contact an admin if you need help clearing the space.</p>
      HTML
      body_text: <<~TEXT
        Hi {{member_name}},

        This is a final reminder about the parking #{kind} for the project at {{location}}, which expired on {{expires_at}}.

        Description: {{description}}

        If the project is not removed promptly, your belongings may be disposed of.

        Contact an admin if you need help clearing the space.
      TEXT
    }
  end
end
