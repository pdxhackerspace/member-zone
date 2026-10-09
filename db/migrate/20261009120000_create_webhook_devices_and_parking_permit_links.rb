class CreateWebhookDevicesAndParkingPermitLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_devices do |t|
      t.string :name, null: false
      t.text :description
      t.boolean :enabled, null: false, default: true
      t.string :token_digest, null: false
      t.string :token_hint
      t.datetime :last_used_at
      t.string :last_used_ip
      t.timestamps
    end
    add_index :webhook_devices, :name, unique: true
    add_index :webhook_devices, :token_digest, unique: true
    add_index :webhook_devices, :enabled

    change_table :parking_notices, bulk: true do |t|
      t.references :webhook_device, foreign_key: { on_delete: :nullify }, index: true
      t.datetime :details_requested_at
      t.datetime :details_completed_at
    end
    add_index :parking_notices, :details_requested_at
    add_index :parking_notices, :details_completed_at

    create_table :parking_permit_links do |t|
      t.references :user, null: false, foreign_key: true
      t.references :webhook_device, foreign_key: { on_delete: :nullify }
      t.references :parking_notice, foreign_key: { on_delete: :cascade }
      t.string :purpose, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :submitted_at
      t.timestamps
    end
    add_index :parking_permit_links, :token_digest, unique: true
    add_index :parking_permit_links, :expires_at
  end
end
