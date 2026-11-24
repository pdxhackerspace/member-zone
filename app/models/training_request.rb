class TrainingRequest < ApplicationRecord
  # pending: still on every trainer's dashboard, whether or not someone has replied.
  # responded: training was recorded. The member can acknowledge that notice.
  # closed: a trainer dismissed it without recording training.
  STATUSES = %w[pending responded closed].freeze

  belongs_to :user
  belongs_to :training_topic
  belongs_to :responded_by, class_name: 'User', optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :share_contact_info, inclusion: { in: [true, false] }
  validates :training_topic_id, uniqueness: {
    scope: :user_id,
    conditions: -> { where(status: 'pending') },
    message: 'already has an active request for this member'
  }

  scope :pending, -> { where(status: 'pending') }
  scope :responded, -> { where(status: 'responded') }
  scope :closed, -> { where(status: 'closed') }
  scope :not_dismissed, -> { where(dismissed_at: nil) }
  scope :dismissed, -> { where.not(dismissed_at: nil) }
  scope :newest_first, -> { order(created_at: :desc) }

  # Still waiting on a trainer. A reply does not remove a request; recording the
  # training or dismissing it does, and either one drops it for every trainer of the topic.
  scope :open_for_trainers, -> { pending }

  # Training was recorded and the member has not dismissed the notice. A reply alone
  # does not land here.
  scope :awaiting_member_acknowledgement, -> { responded.not_dismissed }

  # Open requests for topics this person can train, newest within each topic.
  def self.for_trainer_dashboard(user)
    open_for_trainers
      .where(training_topic_id: user.training_topics.select(:id))
      .joins(:training_topic)
      .includes(:training_topic, :user, :responded_by)
      .order(Arel.sql('training_topics.name ASC, training_requests.created_at DESC'))
  end

  def pending?
    status == 'pending'
  end

  def responded?
    status == 'responded'
  end

  def closed?
    status == 'closed'
  end

  def dismissed?
    dismissed_at.present?
  end

  def replied?
    responded_at.present?
  end

  # Training was recorded. This is what takes the request off the trainer dashboards
  # and shows the member a "training completed" notice.
  def respond!(responder)
    update!(status: 'responded', responded_by: responder, responded_at: Time.current)
  end

  # Someone answered the member. The request stays open for every trainer of the topic.
  def record_reply!(responder)
    return unless pending?

    update!(responded_by: responder, responded_at: Time.current)
  end

  # Take the request off every trainer's dashboard without recording training.
  def dismiss_for_trainers!
    return unless pending?

    update!(status: 'closed')
  end

  def dismiss!
    return if dismissed?

    update!(dismissed_at: Time.current)
  end

  def self.clear_pending_for!(user:, training_topic:, responded_by: nil)
    pending.where(user: user, training_topic: training_topic).find_each do |request|
      request.update!(status: 'responded', responded_by: responded_by, responded_at: Time.current)
    end
  end
end
