# One run of an announcer for one member's arrival (or a test run from the settings page).
# Doubles as the record Announcer#announced_recently? reads to avoid repeating itself.
class AnnouncerRun < ApplicationRecord
  STATUSES = %w[queued running success failed].freeze

  belongs_to :announcer
  belongs_to :user
  belongs_to :access_log, optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
end
