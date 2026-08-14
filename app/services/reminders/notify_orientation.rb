module Reminders
  # Sends the building access orientation reminder. Disabled by default; how long after
  # approval the first one goes out, and the gap between them after that, both come from
  # MembershipSetting.orientation_reminder_repeat_days.
  class NotifyOrientation
    def self.call(now: Time.current)
      new(now: now).call
    end

    def self.record_delivery!(user, at: Time.current)
      user.with_lock do
        user.update_column(:orientation_reminder_sent_at, at)
      end
    end

    def initialize(now:)
      @now = now
    end

    def call
      return unless ReminderSetting.enabled?('orientation')

      OrientationEligibility.due(now: @now).find_each { |user| notify_user(user) }
    end

    private

    def notify_user(user)
      user.with_lock do
        return unless OrientationEligibility.due?(user, now: @now)

        extras = MemberMailer.orientation_template_extras(user, now: @now)
        result = deliver_reminder_mail(user, extras)
        return if result.nil?

        # Mail held for review has not reached the member yet, so the clock on the next
        # reminder only starts once something actually went out.
        self.class.record_delivery!(user, at: @now) if result.is_a?(QueuedMail::ImmediateDelivery)
      end
    end

    def deliver_reminder_mail(user, extras)
      QueuedMail.enqueue(:orientation_reminder, user,
                         reason: "Orientation not recorded for #{user.display_name}", **extras)
    rescue StandardError => e
      Rails.logger.error("[NotifyOrientation] user_id=#{user.id} delivery failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
