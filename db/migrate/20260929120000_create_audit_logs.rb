# Audit log sources are external programs run on a schedule; their output lands in
# audit_log_entries, which is append-only. Entries are matched against per-source alert rules.
class CreateAuditLogs < ActiveRecord::Migration[8.1]
  def change
    enable_extension 'pg_trgm'

    create_audit_log_sources
    create_audit_log_alert_rules
    create_audit_log_runs
    create_audit_log_entries
  end

  private

  def create_audit_log_sources
    create_table :audit_log_sources do |t|
      t.string :name, null: false
      t.text :description
      t.string :script_path, null: false
      t.string :script_arguments
      t.text :environment_variables
      t.string :run_interval, null: false, default: 'daily'
      t.boolean :enabled, null: false, default: true
      t.references :training_topic, foreign_key: { on_delete: :nullify }
      t.string :run_status, null: false, default: 'unknown'
      t.datetime :last_run_at
      t.datetime :last_entry_at
      t.timestamps
    end
    add_index :audit_log_sources, :name, unique: true
    add_index :audit_log_sources, :enabled
  end

  def create_audit_log_alert_rules
    create_table :audit_log_alert_rules do |t|
      t.references :audit_log_source, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :pattern, null: false
      t.boolean :case_insensitive, null: false, default: true
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
  end

  def create_audit_log_runs
    create_table :audit_log_runs do |t|
      t.references :audit_log_source, null: false, foreign_key: { on_delete: :cascade }
      t.string :command_line
      t.text :output
      t.integer :exit_code
      t.string :status, null: false, default: 'running'
      t.integer :entries_added, null: false, default: 0
      t.timestamps
    end
    add_index :audit_log_runs, :created_at
  end

  def create_audit_log_entries
    create_table :audit_log_entries do |t|
      t.references :audit_log_source, null: false, foreign_key: { on_delete: :restrict }
      t.datetime :occurred_at, null: false
      t.text :message, null: false
      t.jsonb :raw, null: false, default: {}
      t.string :fingerprint, null: false
      t.text :explanation
      t.references :explained_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :explained_at
      t.bigint :matched_rule_ids, array: true, null: false, default: []
      t.datetime :alerted_at
      t.timestamps
    end
    add_index :audit_log_entries, %i[audit_log_source_id fingerprint], unique: true
    add_index :audit_log_entries, %i[audit_log_source_id occurred_at]
    add_index :audit_log_entries, :occurred_at
    add_index :audit_log_entries, :raw, using: :gin
    add_index :audit_log_entries, :message, using: :gin, opclass: :gin_trgm_ops,
                                            name: 'index_audit_log_entries_on_message_trgm'
  end
end
