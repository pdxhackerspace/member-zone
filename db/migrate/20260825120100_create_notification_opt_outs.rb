class CreateNotificationOptOuts < ActiveRecord::Migration[8.1]
  def change
    create_table :notification_opt_outs do |t|
      t.references :user, null: false, foreign_key: true
      t.string :category, null: false
      t.string :channel, null: false
      t.string :source, null: false, default: 'self_service'

      t.timestamps
    end

    add_index :notification_opt_outs, %i[user_id category channel], unique: true,
                                                                  name: 'index_notification_opt_outs_on_user_category_channel'
    add_index :notification_opt_outs, %i[category channel]
  end
end
