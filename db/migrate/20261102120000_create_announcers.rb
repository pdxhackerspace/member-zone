class CreateAnnouncers < ActiveRecord::Migration[8.1]
  def change
    create_table :announcers do |t|
      t.string :name, null: false
      t.text :description
      t.string :script_path, null: false
      t.string :script_arguments
      t.text :environment_variables
      t.boolean :enabled, null: false, default: false
      t.integer :display_order, null: false, default: 0
      t.integer :repeat_after_minutes, null: false, default: 120
      t.datetime :last_run_at
      t.string :last_run_status, null: false, default: 'unknown'
      t.timestamps
    end
    add_index :announcers, :name, unique: true
    add_index :announcers, %i[enabled display_order]

    create_table :announcer_subscriptions do |t|
      t.references :announcer, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true, index: false
      t.timestamps
    end
    add_index :announcer_subscriptions, %i[user_id announcer_id], unique: true

    create_table :announcer_runs do |t|
      t.references :announcer, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: true
      t.references :access_log, foreign_key: { on_delete: :nullify }
      t.string :status, null: false, default: 'queued'
      t.boolean :test_run, null: false, default: false
      t.integer :exit_code
      t.text :output
      t.datetime :finished_at
      t.timestamps
    end
    add_index :announcer_runs, %i[announcer_id user_id created_at]
    add_index :announcer_runs, %i[announcer_id created_at]

    add_column :users, :announce_arrivals, :boolean, null: false, default: false
    add_column :default_settings, :arrival_locations, :string, array: true, null: false, default: []
  end
end
