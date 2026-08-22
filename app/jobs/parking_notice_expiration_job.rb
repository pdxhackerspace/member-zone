class ParkingNoticeExpirationJob < ApplicationJob
  queue_as :default

  def perform
    Reminders::NotifyParkingNotices.call
  end
end
