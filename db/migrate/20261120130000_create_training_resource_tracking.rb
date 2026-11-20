# Records edits to a topic's links and documents, and the last copy we saw of each
# linked page, so a digest can tell trained members and trainers what changed.
class CreateTrainingResourceTracking < ActiveRecord::Migration[8.1]
  def up
    create_table :training_resource_changes do |t|
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }
      t.jsonb :details, null: false, default: {}
      t.string :kind, null: false
      t.datetime :notified_at
      t.datetime :occurred_at, null: false
      t.bigint :resource_id
      t.string :resource_type
      t.string :title, null: false
      t.references :training_topic, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.timestamps
    end
    add_index :training_resource_changes, :notified_at
    add_index :training_resource_changes, %i[training_topic_id occurred_at],
              name: 'index_training_resource_changes_on_topic_and_occurred_at'

    create_table :training_topic_link_snapshots do |t|
      t.string :candidate_digest
      t.string :candidate_etag
      t.string :candidate_last_modified
      t.text :candidate_text
      t.datetime :changed_at
      t.datetime :checked_at
      t.string :digest
      t.string :error
      t.string :etag
      t.integer :flap_count, null: false, default: 0
      t.string :last_modified
      t.string :status, null: false, default: 'baseline'
      t.text :text
      t.references :training_topic_link, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.timestamps
    end

    # Existing databases learn about the new template and reminder here. Fresh
    # databases get both from db:seed, and seed_defaults! leaves anything an
    # admin has already edited alone.
    EmailTemplate.seed_defaults!
    ReminderSetting.seed_defaults!
  end

  def down
    drop_table :training_topic_link_snapshots
    drop_table :training_resource_changes
    EmailTemplate.where(key: 'training_resources_updated').delete_all
    ReminderSetting.where(key: 'training_resource_updates').delete_all
  end
end
