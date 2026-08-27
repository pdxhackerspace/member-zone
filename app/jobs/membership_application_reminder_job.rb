class MembershipApplicationReminderJob < ApplicationJob
  queue_as :default

  def perform
    Reminders::NotifyApplicationReview.call
  end
end
