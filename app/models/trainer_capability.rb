class TrainerCapability < ApplicationRecord
  belongs_to :user
  belongs_to :training_topic

  validates :user_id, uniqueness: { scope: :training_topic_id }

  # People an admin may name as the trainer when recording a session someone else taught:
  # anyone who can train a topic, plus the account doing the recording.
  def self.attributable_trainers(including: nil)
    ids = distinct.pluck(:user_id)
    ids << including.id if including
    User.where(id: ids.compact.uniq).ordered_by_display_name
  end

  after_create :sync_can_train_group
  after_destroy :sync_can_train_group
  after_commit :enqueue_trainer_authentik_sync, on: %i[create destroy]

  private

  def enqueue_trainer_authentik_sync
    return if Current.skip_authentik_sync

    Authentik::UserSyncJob.perform_later(user_id, %w[can_train])
  end

  def sync_can_train_group
    Authentik::ApplicationGroupMembershipSyncJob.perform_later(%w[can_train])
  end
end
