module Reminders
  class NotifyLapsedAccess
    def self.call(now: Time.current)
      new(now: now).call
    end

    def self.record_delivery!(user, at: Time.current)
      user.with_lock do
        user.update_column(:lapsed_access_reminder_sent_at, at)
      end
    end

    def initialize(now:)
      @now = now
    end

    def call
      return unless ReminderSetting.enabled?('lapsed_access')

      LapsedAccessEligibility.due(now: @now).find_each do |user|
        notify_user(user)
      end
    end

    private

    def notify_user(user)
      user.with_lock do
        return unless LapsedAccessEligibility.due?(user, now: @now)

        extras = MemberMailer.lapsed_access_template_extras(user)
        result = deliver_reminder_mail(user, extras)
        return if result.nil?

        self.class.record_delivery!(user, at: @now) if result.is_a?(QueuedMail::ImmediateDelivery)
      end
    end

    def deliver_reminder_mail(user, extras)
      QueuedMail.enqueue(:lapsed_access_reminder, user,
                         reason: "Lapsed member accessed yesterday: #{user.display_name}",
                         **extras)
    rescue StandardError => e
      Rails.logger.error("[NotifyLapsedAccess] user_id=#{user.id} delivery failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
