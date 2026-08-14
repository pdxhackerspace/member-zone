class OrientationReminderJob < ApplicationJob
  queue_as :default

  def perform
    Reminders::NotifyOrientation.call
  end
end
