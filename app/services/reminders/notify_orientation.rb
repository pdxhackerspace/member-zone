module Reminders
  # Sends the building access orientation reminder. Disabled by default; the cadence comes
  # from the reminder's settings row and counts from the day the membership was approved.
  class NotifyOrientation
    def self.call(now: Time.current)
      new(now: now).call
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
        OrientationEligibility.record_delivery!(user, at: @now) if result.is_a?(QueuedMail::ImmediateDelivery)
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
