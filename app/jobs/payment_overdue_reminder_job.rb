class PaymentOverdueReminderJob < ApplicationJob
  queue_as :default

  def perform
    Reminders::NotifyPaymentOverdue.call
  end
end
