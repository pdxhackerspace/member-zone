class Training < ApplicationRecord
  belongs_to :trainee, class_name: 'User'
  belongs_to :trainer, class_name: 'User', optional: true
  belongs_to :training_topic

  validates :trained_at, presence: true

  scope :recent, -> { order(trained_at: :desc) }

  after_create :sync_trained_in_group, :clear_pending_training_requests, :start_membership_grace_period
  after_destroy :sync_trained_in_group
  after_commit :enqueue_trainee_authentik_sync, on: %i[create destroy]
  after_commit :sync_required_access_controllers, on: %i[create destroy]

  private

  # Building access training is what turns an approved applicant into a member who is
  # expected to start paying, so it opens their grace period. No-op for every other
  # topic and for anyone who is not a new member.
  def start_membership_grace_period
    return unless training_topic_id == TrainingTopic.building_access&.id

    trainee.grant_building_access!
  end

  # When a topic is required by an access controller type, a training change alters who
  # is authorized, so re-sync every controller of that type.
  def sync_required_access_controllers
    return if training_topic_id.blank?
    return unless AccessControllerTypeTrainingTopic.exists?(training_topic_id: training_topic_id)

    AccessControllerTrainingSyncJob.perform_later(training_topic_id)
  end

  def enqueue_trainee_authentik_sync
    return if Current.skip_authentik_sync
    return if trainee_id.blank?

    Authentik::UserSyncJob.perform_later(trainee_id, %w[trained_on])
  end

  def sync_trained_in_group
    Authentik::ApplicationGroupMembershipSyncJob.perform_later(%w[trained_in])
  end

  def clear_pending_training_requests
    TrainingRequest.clear_pending_for!(
      user: trainee,
      training_topic: training_topic,
      responded_by: trainer
    )
  end
end
