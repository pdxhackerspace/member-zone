class AddTrainedMemberListingToTrainingTopics < ActiveRecord::Migration[8.1]
  def change
    add_column :training_topics, :trained_members_visible, :boolean, null: false, default: false
    add_column :training_topics, :trained_members_contactable, :boolean, null: false, default: false
  end
end
