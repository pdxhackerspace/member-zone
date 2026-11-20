module Reminders
  # Whether an arrival should email the member about parking they still have open.
  #
  # One email per arrival, listing every notice worth mentioning. The pace is a repeat
  # window in minutes, the same idea as an announcer: the day-counted cadence does not
  # apply, and a notice issued inside the window is left out because its issued email
  # has only just gone out. A pending clearance request is left out too — staff already
  # have it.
  class ParkingArrivalEligibility
    extend Cadence

    REMINDER_KEY = 'parking_arrival'.freeze
    MAILER_ACTION = 'parking_arrival_reminder'.freeze

    class << self
      def reminder_key
        REMINDER_KEY
      end

      # Not a day-counted sequence. A nil anchor keeps the send count accumulating;
      # the window reads last_sent_at instead.
      def anchor(_user)
        nil
      end

      def repeat_after_minutes
        ReminderSetting.for_key(REMINDER_KEY).repeat_after_minutes
      end

      # Why this arrival should stay quiet, or nil when a reminder should go out.
      def skip_reason(user, access_log:, now: Time.current)
        return 'reminder is disabled' unless reminder_enabled?
        return 'no access log' if access_log.nil?

        entry_skip_reason(user, access_log, now: now) ||
          member_skip_reason(user) ||
          window_skip_reason(user, now: now) ||
          notice_skip_reason(user, now: now)
      end

      def notices_for(user, now: Time.current)
        mentionable_for(user, now: now).order(:expires_at).to_a
      end

      def members_with_open_notices
        User.where(id: open_notice_members.select(:user_id)).order(:full_name)
      end

      def count_with_open_notices
        members_with_open_notices.count
      end

      def reminded_today_count(now: Time.current)
        ReminderDelivery.for_reminder(REMINDER_KEY).where(last_sent_at: now.all_day).count
      end

      def open_notice_counts(user_ids)
        return {} if user_ids.blank?

        open_notice_members.where(user_id: user_ids).group(:user_id).count
      end

      private

      def entry_skip_reason(user, access_log, now:)
        return 'no member matched the entry' if user.nil?
        return 'entry is not an arrival' unless access_log.arrival?
        return "entry is older than #{AccessLog::STALE_AFTER.inspect}" unless access_log.fresh?(now: now)

        nil
      end

      def member_skip_reason(user)
        return 'member is a service account' if user.service_account?
        return 'member is banned or deceased' if user.terminal_membership_state?
        return 'member has no email address' if user.email.blank?
        return 'member opted out' if opted_out?(user)

        nil
      end

      def window_skip_reason(user, now:)
        return nil if repeat_after_minutes.zero?

        last_sent_at = ReminderDelivery.state_for(REMINDER_KEY, user)&.last_sent_at
        return nil if last_sent_at.nil? || last_sent_at <= now - repeat_after

        'already reminded at ' \
          "#{last_sent_at.iso8601}; repeat window of #{repeat_after_minutes} minutes ends at " \
          "#{(last_sent_at + repeat_after).iso8601}"
      end

      def notice_skip_reason(user, now:)
        return nil if mentionable_for(user, now: now).exists?

        pending = open_for(user).where(clearance_requested_at: nil)
        return 'every open notice was issued inside the repeat window' if pending.exists?
        return 'clearance has already been requested' if open_for(user).exists?

        'no open notice to mention'
      end

      def opted_out?(user)
        Notifications::DeliveryGate.blocked?(mailer_action: MAILER_ACTION, user: user)
      end

      def mentionable_for(user, now:)
        scope = open_for(user).where(clearance_requested_at: nil)
        return scope if repeat_after_minutes.zero?

        scope.where(created_at: ..(now - repeat_after))
      end

      def open_for(user)
        ParkingNotice.remindable.where(id: ParkingNoticeMember.where(user_id: user.id).select(:parking_notice_id))
      end

      def open_notice_members
        ParkingNoticeMember.joins(:parking_notice).merge(ParkingNotice.remindable)
      end

      def repeat_after
        repeat_after_minutes.minutes
      end
    end
  end
end
