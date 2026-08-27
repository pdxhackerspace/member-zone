class AddApplicationReviewReminder < ActiveRecord::Migration[8.1]
  def up
    add_column :reminder_settings, :remind_under_review, :boolean, default: false, null: false

    execute(<<~SQL.squish)
      INSERT INTO reminder_settings (key, name, description, enabled, allow_opt_out, remind_under_review, created_at, updated_at)
      VALUES (
        'application_review',
        'Application review reminder',
        'Reminds executive reviewers when membership applications are waiting for a decision.',
        FALSE,
        FALSE,
        FALSE,
        NOW(),
        NOW()
      )
      ON CONFLICT (key) DO NOTHING
    SQL
  end

  def down
    execute("DELETE FROM reminder_settings WHERE key = 'application_review'")
    remove_column :reminder_settings, :remind_under_review
  end
end
