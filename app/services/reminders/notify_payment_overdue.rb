module Reminders
  # Sends the overdue dues reminder. Disabled by default; the cadence between reminders
  # to the same member comes from MembershipSetting.payment_overdue_reminder_repeat_days.
  class NotifyPaymentOverdue
    def self.call(now: Time.current)
      new(now: now).call
    end

    def self.record_delivery!(user, at: Time.current)
      user.with_lock do
        user.update_column(:payment_overdue_reminder_sent_at, at)
      end
    end

    def initialize(now:)
      @now = now
    end

    def call
      return unless ReminderSetting.enabled?('payment_overdue')

      PaymentOverdueEligibility.candidates(now: @now).find_each do |user|
        notify_user(user) if PaymentOverdueEligibility.due?(user, now: @now)
      end
    end

    private

    def notify_user(user)
      user.with_lock do
        return unless PaymentOverdueEligibility.due?(user, now: @now)

        result = deliver_reminder_mail(user)
        return if result.nil?

        # Mail held for review has not reached the member yet, so the clock on the next
        # reminder only starts once something actually went out.
        self.class.record_delivery!(user, at: @now) if result.is_a?(QueuedMail::ImmediateDelivery)
      end
    end

    def deliver_reminder_mail(user)
      QueuedMail.enqueue(:payment_past_due, user, reason: "Dues overdue for #{user.display_name}",
                                                  days_overdue: days_overdue(user))
    rescue StandardError => e
      Rails.logger.error("[NotifyPaymentOverdue] user_id=#{user.id} delivery failed: #{e.class}: #{e.message}")
      nil
    end

    # Nil when we cannot tell — the template drops the phrase rather than guessing.
    def days_overdue(user)
      paid_through = user.dues_paid_through_at
      return nil if paid_through.blank? || paid_through > @now

      ((@now - paid_through) / 1.day).floor
    end
  end
end
