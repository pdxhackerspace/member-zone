class CreateEmailNotificationOptOuts < ActiveRecord::Migration[8.1]
  def change
    create_table :email_notification_opt_outs do |t|
      t.string :email, null: false
      t.string :email_lookup_digest
      t.string :category, null: false
      t.string :channel, null: false
      t.string :source, null: false, default: 'email_link'

      t.timestamps
    end

    add_index :email_notification_opt_outs, %i[email_lookup_digest category channel],
              unique: true,
              name: 'index_email_opt_outs_on_digest_category_channel'
    add_index :email_notification_opt_outs, %i[category channel]
  end
end
