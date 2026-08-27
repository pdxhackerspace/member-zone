class AddAllowOptOutToReminderSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :reminder_settings, :allow_opt_out, :boolean, default: true, null: false

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE reminder_settings SET allow_opt_out = false WHERE key = 'parking_notices'
        SQL
      end
    end
  end
end
