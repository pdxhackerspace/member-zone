# Credential providers are external programs that issue, revoke, pause and health-check
# credentials (API keys, app passwords, OAuth clients) in other systems. A credential row
# records one issued credential; the secret itself is never stored, only the first and last
# four characters of each secret field. Credential runs log every program call.
class CreateCredentials < ActiveRecord::Migration[8.1]
  def change
    create_credential_providers
    create_credential_provider_training_topics
    create_credentials
    create_credential_runs
  end

  private

  def create_credential_providers
    create_table :credential_providers do |t|
      t.string :name, null: false
      t.text :description
      t.string :script_path, null: false
      t.string :script_arguments
      t.text :environment_variables
      t.boolean :enabled, null: false, default: true
      t.boolean :self_service, null: false, default: true
      t.integer :max_per_member, null: false, default: 5
      t.jsonb :schema, null: false, default: {}
      t.datetime :schema_fetched_at
      t.text :schema_error
      t.string :health_status, null: false, default: 'unknown'
      t.text :health_message
      t.datetime :last_health_check_at
      t.datetime :last_healthy_at
      t.timestamps
    end
    add_index :credential_providers, :name, unique: true
    add_index :credential_providers, %i[enabled health_status]
  end

  def create_credential_provider_training_topics
    create_table :credential_provider_training_topics do |t|
      t.references :credential_provider, null: false, foreign_key: { on_delete: :cascade },
                                         index: { name: 'idx_cp_training_topics_on_provider' }
      t.references :training_topic, null: false, foreign_key: true,
                                    index: { name: 'idx_cp_training_topics_on_topic' }
      t.timestamps
    end
    add_index :credential_provider_training_topics, %i[credential_provider_id training_topic_id],
              unique: true, name: 'idx_cp_training_topics_unique'
  end

  def create_credentials
    create_table :credentials do |t|
      t.references :credential_provider, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: true, index: false
      t.references :issued_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :revoked_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :rotated_from, foreign_key: { to_table: :credentials, on_delete: :nullify }
      t.string :label
      t.uuid :request_id, null: false
      t.string :external_id
      t.jsonb :field_hints, null: false, default: {}
      t.string :status, null: false, default: 'pending'
      t.datetime :issued_at
      t.datetime :expires_at
      t.datetime :expiry_warning_sent_at
      t.datetime :paused_at
      t.datetime :revoked_at
      t.string :revocation_reason
      t.integer :revoke_attempts, null: false, default: 0
      t.datetime :last_revoke_error_at
      t.timestamps
    end
    add_index :credentials, :request_id, unique: true
    add_index :credentials, %i[user_id status]
    add_index :credentials, %i[status expires_at]
    add_index :credentials, %i[credential_provider_id status]
    add_index :credentials, %i[credential_provider_id external_id]
  end

  def create_credential_runs
    create_table :credential_runs do |t|
      t.references :credential_provider, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :credential, foreign_key: { on_delete: :nullify }
      t.string :action, null: false
      t.string :command_line
      t.string :status, null: false, default: 'running'
      t.integer :exit_code
      t.text :output
      t.integer :duration_ms
      t.timestamps
    end
    add_index :credential_runs, %i[credential_provider_id created_at]
  end
end
