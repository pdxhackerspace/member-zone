class AccessLog < ApplicationRecord
  # Actions that mean someone came in. Locking a door is what people do on the way out, and
  # enabling a tool isn't arriving anywhere, so neither is ever announced.
  ARRIVAL_ACTIONS = %w[opened unlocked].freeze

  belongs_to :user, optional: true
  has_many :announcer_runs, dependent: :nullify

  scope :recent, -> { where.not(logged_at: nil).order(logged_at: :desc) }

  # Entries the member has not yet been told about by the lapsed access reminder. One reminder
  # covers every entry in the window, so all of them are stamped together when it goes out.
  scope :lapsed_access_unnotified, -> { where(lapsed_access_reminder_sent_at: nil) }

  # Every location the logs have named, for picking which ones are outside doors.
  def self.known_locations
    where.not(location: [nil, '']).distinct.order(:location).pluck(:location)
  end

  # A member coming in through one of the outside doors listed in DefaultSetting.
  def arrival?
    ARRIVAL_ACTIONS.include?(action.to_s.downcase) && DefaultSetting.arrival_location?(location)
  end
end
