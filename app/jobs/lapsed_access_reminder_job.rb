class LapsedAccessReminderJob < ApplicationJob
  queue_as :default

  def perform
    Reminders::NotifyLapsedAccess.call
  end
end
