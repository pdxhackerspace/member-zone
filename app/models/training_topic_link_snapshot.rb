class TrainingTopicLinkSnapshot < ApplicationRecord
  PROBLEM_STATUSES = %w[error untrackable too_large].freeze

  belongs_to :training_topic_link, inverse_of: :content_snapshot

  def problem?
    PROBLEM_STATUSES.include?(status)
  end

  def problem_phrase
    case status
    when 'error' then "Can't be read (#{error})"
    when 'untrackable' then "Changes can't be tracked"
    when 'too_large' then 'Page is too large to compare'
    end
  end
end
