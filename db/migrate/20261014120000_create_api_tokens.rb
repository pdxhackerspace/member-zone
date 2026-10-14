class CreateApiTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :api_tokens do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      # Nullable so deleting a person never takes a service account's token with it; reminders
      # for a token with no contact go to the token managers.
      t.references :contact_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :name, null: false
      t.text :description
      t.string :token_digest, null: false
      t.string :token_hint
      t.string :scopes, array: true, null: false, default: []
      t.datetime :expires_at, null: false
      t.datetime :last_extended_at
      t.datetime :suspended_at
      t.references :suspended_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :suspended_reason
      t.datetime :revoked_at
      t.references :revoked_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :revoked_reason
      t.datetime :last_used_at
      t.string :last_used_ip
      t.timestamps
    end

    add_index :api_tokens, :token_digest, unique: true
    add_index :api_tokens, :expires_at
    add_index :api_tokens, :revoked_at
    add_index :api_tokens, :scopes, using: :gin

    add_column :default_settings, :api_token_max_lifetime_days, :integer, null: false, default: 365
  end
end
