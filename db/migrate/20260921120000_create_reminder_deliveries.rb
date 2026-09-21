class CreateReminderDeliveries < ActiveRecord::Migration[8.1]
  # Every reminder used to keep its own count in its own place: a timestamp column per
  # reminder on users, four phase columns on parking_notices, a count on
  # application_verifications. One row per reminder per subject replaces all of them, which
  # is what makes a maximum number of reminders expressible at all.
  def up
    create_table :reminder_deliveries do |t|
      t.string :reminder_key, null: false
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.datetime :anchor_at
      t.integer :sent_count, null: false, default: 0
      t.datetime :first_sent_at
      t.datetime :last_sent_at

      t.timestamps
    end

    add_index :reminder_deliveries, %i[reminder_key subject_type subject_id],
              unique: true, name: 'index_reminder_deliveries_on_key_and_subject'
    add_index :reminder_deliveries, %i[reminder_key last_sent_at]
    add_index :reminder_deliveries, %i[subject_type subject_id]

    backfill_user_reminders
    backfill_application_link_reminders
    backfill_staff_application_reminders
    backfill_parking_notice_reminders
  end

  def down
    drop_table :reminder_deliveries
  end

  private

  # The old columns only ever recorded the last send, so every backfilled member starts at a
  # count of one. That understates anyone who has been reminded repeatedly, which is the safe
  # direction to be wrong in: they get the rest of their sequence rather than being cut off.
  def backfill_user_reminders
    {
      'slack_signup' => 'slack_signup_reminder_sent_at',
      'orientation' => 'orientation_reminder_sent_at',
      'payment_overdue' => 'payment_overdue_reminder_sent_at',
      'lapsed_access' => 'lapsed_access_reminder_sent_at'
    }.each do |reminder_key, column|
      execute(<<~SQL.squish)
        INSERT INTO reminder_deliveries
          (reminder_key, subject_type, subject_id, sent_count, first_sent_at, last_sent_at, created_at, updated_at)
        SELECT '#{reminder_key}', 'User', users.id, 1, users.#{column}, users.#{column}, NOW(), NOW()
        FROM users
        WHERE users.#{column} IS NOT NULL
      SQL
    end
  end

  # The only reminder that already counted its sends, so its count carries over as it stands.
  def backfill_application_link_reminders
    execute(<<~SQL.squish)
      INSERT INTO reminder_deliveries
        (reminder_key, subject_type, subject_id, anchor_at, sent_count, first_sent_at, last_sent_at,
         created_at, updated_at)
      SELECT 'application_link', 'ApplicationVerification', id, created_at,
             GREATEST(application_link_reminder_count, 1),
             application_link_reminder_sent_at, application_link_reminder_sent_at, NOW(), NOW()
      FROM application_verifications
      WHERE application_link_reminder_sent_at IS NOT NULL
    SQL
  end

  def backfill_staff_application_reminders
    execute(<<~SQL.squish)
      INSERT INTO reminder_deliveries
        (reminder_key, subject_type, subject_id, anchor_at, sent_count, first_sent_at, last_sent_at,
         created_at, updated_at)
      SELECT 'staff_application', 'MembershipApplication', id,
             COALESCE(submitted_at, created_at), 1,
             application_reminder_sent_at, application_reminder_sent_at, NOW(), NOW()
      FROM membership_applications
      WHERE application_reminder_sent_at IS NOT NULL
    SQL
  end

  # Parking is the one subject whose count is knowable: each of the four phases stamped its
  # own column, so the number of stamps is the number of reminders that went out.
  def backfill_parking_notice_reminders
    execute(<<~SQL.squish)
      INSERT INTO reminder_deliveries
        (reminder_key, subject_type, subject_id, anchor_at, sent_count, first_sent_at, last_sent_at,
         created_at, updated_at)
      SELECT 'parking_notices', 'ParkingNotice', id, expires_at,
             (CASE WHEN pre_expiration_reminder_sent_at IS NOT NULL THEN 1 ELSE 0 END
              + CASE WHEN expiration_notice_sent_at IS NOT NULL THEN 1 ELSE 0 END
              + CASE WHEN overdue_reminder_sent_at IS NOT NULL THEN 1 ELSE 0 END
              + CASE WHEN final_reminder_sent_at IS NOT NULL THEN 1 ELSE 0 END),
             LEAST(pre_expiration_reminder_sent_at, expiration_notice_sent_at,
                   overdue_reminder_sent_at, final_reminder_sent_at),
             GREATEST(pre_expiration_reminder_sent_at, expiration_notice_sent_at,
                      overdue_reminder_sent_at, final_reminder_sent_at),
             NOW(), NOW()
      FROM parking_notices
      WHERE pre_expiration_reminder_sent_at IS NOT NULL
         OR expiration_notice_sent_at IS NOT NULL
         OR overdue_reminder_sent_at IS NOT NULL
         OR final_reminder_sent_at IS NOT NULL
    SQL
  end
end
