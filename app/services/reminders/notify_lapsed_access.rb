module Reminders
  class NotifyLapsedAccess
    def self.call(now: Time.current)
      new(now: now).call
    end

    # One reminder speaks for every visit it covered, so all of those entries are stamped even
    # though only one email goes out. Entries logged after this point stay unstamped and make the
    # member due again on the next daily run.
    def self.record_delivery!(user, at: Time.current, access_log_ids: nil)
      user.with_lock do
        user.update_column(:lapsed_access_reminder_sent_at, at)
        mark_access_logs_notified!(user, at: at, access_log_ids: access_log_ids)
      end
    end

    def self.mark_access_logs_notified!(user, at:, access_log_ids: nil)
      scope = AccessLog.where(user_id: user.id).lapsed_access_unnotified
      scope = if access_log_ids.present?
                scope.where(id: access_log_ids)
              else
                scope.where(logged_at: LapsedAccessEligibility.window(now: at))
              end

      scope.update_all(lapsed_access_reminder_sent_at: at, updated_at: at)
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

        access_log_ids = LapsedAccessEligibility.unnotified_access_log_ids(user, now: @now)
        result = deliver_reminder_mail(user, access_log_ids)
        return if result.nil?

        return unless result.is_a?(QueuedMail::ImmediateDelivery)

        self.class.record_delivery!(user, at: @now, access_log_ids: access_log_ids)
      end
    end

    # +access_log_ids+ rides along in the queued mail's mailer_args so that a message held for
    # review stamps exactly the visits it described, not whatever the window covers on send day.
    def deliver_reminder_mail(user, access_log_ids)
      extras = MemberMailer.lapsed_access_template_extras(user)

      QueuedMail.enqueue(:lapsed_access_reminder, user,
                         reason: reason_for(user, access_log_ids),
                         access_log_ids: access_log_ids,
                         **extras)
    rescue StandardError => e
      Rails.logger.error("[NotifyLapsedAccess] user_id=#{user.id} delivery failed: #{e.class}: #{e.message}")
      nil
    end

    def reason_for(user, access_log_ids)
      visits = access_log_ids.size
      "Lapsed member badged in #{visits} #{'time'.pluralize(visits)}: #{user.display_name}"
    end
  end
end
