class AccessLog < ApplicationRecord
  belongs_to :user, optional: true

  scope :recent, -> { where.not(logged_at: nil).order(logged_at: :desc) }

  # Entries the member has not yet been told about by the lapsed access reminder. One reminder
  # covers every entry in the window, so all of them are stamped together when it goes out.
  scope :lapsed_access_unnotified, -> { where(lapsed_access_reminder_sent_at: nil) }
end
