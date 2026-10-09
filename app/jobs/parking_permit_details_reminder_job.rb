class ParkingPermitDetailsReminderJob < ApplicationJob
  queue_as :default

  def perform
    Reminders::NotifyParkingPermitDetails.call
  end
end
