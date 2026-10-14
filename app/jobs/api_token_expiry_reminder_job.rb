class ApiTokenExpiryReminderJob < ApplicationJob
  queue_as :default

  def perform
    Reminders::NotifyApiTokenExpiry.call
  end
end
