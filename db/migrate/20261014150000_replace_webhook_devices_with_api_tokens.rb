# Access control devices now call the API with a service-account token instead of holding a
# webhook device token. Parking permits and permit links remember the API token that issued them.
# No devices were in production, so there is nothing to carry over.
class ReplaceWebhookDevicesWithApiTokens < ActiveRecord::Migration[8.1]
  def change
    add_reference :parking_notices, :api_token, foreign_key: { on_delete: :nullify }
    add_reference :parking_permit_links, :api_token, foreign_key: { on_delete: :nullify }

    remove_reference :parking_notices, :webhook_device, foreign_key: { on_delete: :nullify }, index: true
    remove_reference :parking_permit_links, :webhook_device, foreign_key: { on_delete: :nullify }, index: true

    drop_table :webhook_devices do |t|
      t.string :name, null: false
      t.text :description
      t.boolean :enabled, default: true, null: false
      t.string :token_digest, null: false
      t.string :token_hint
      t.datetime :last_used_at
      t.string :last_used_ip
      t.timestamps
      t.index :enabled
      t.index :name, unique: true
      t.index :token_digest, unique: true
    end
  end
end
