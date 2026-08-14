class CreateNagSettings < ActiveRecord::Migration[8.1]
  def up
    create_table :nag_settings do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      t.boolean :enabled, null: false, default: false

      t.timestamps
    end

    add_index :nag_settings, :key, unique: true
    add_index :nag_settings, :enabled

    seed_slack_signup_setting
  end

  def down
    drop_table :nag_settings
  end

  private

  # Spelled out rather than read from a model CATALOG: this table was later renamed to
  # reminder_settings and NagSetting no longer exists, so the constant cannot be resolved
  # when an older database migrates up through this point.
  def seed_slack_signup_setting
    execute(<<~SQL.squish)
      INSERT INTO nag_settings (key, name, description, enabled, created_at, updated_at)
      VALUES (
        'slack_signup',
        'Slack signup reminder',
        'Gentle reminder to active members without a linked Slack account.',
        FALSE,
        NOW(),
        NOW()
      )
    SQL
  end
end
