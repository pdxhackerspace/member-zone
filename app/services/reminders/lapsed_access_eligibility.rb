module Reminders
  # Inactive members with building access they have not been reminded about yet.
  #
  # The window looks back +ReminderSetting#lookback_days+ from now. Eligibility is driven by
  # access log entries rather than by a per-member timestamp: one reminder stamps every entry in
  # the window, so a member who badged in six times is emailed once, and only a genuinely new
  # entry makes them due again on a later run.
  class LapsedAccessEligibility
    REMINDER_KEY = 'lapsed_access'.freeze
    DEFAULT_LOOKBACK_DAYS = 1

    WITHOUT_PENDING_REMINDER_MAIL_SQL = <<~SQL.squish
      NOT EXISTS (
        SELECT 1
        FROM queued_mails
        WHERE queued_mails.recipient_id = users.id
          AND queued_mails.mailer_action = 'lapsed_access_reminder'
          AND queued_mails.status IN ('pending', 'approved')
          AND queued_mails.sent_at IS NULL
      )
    SQL

    DELIVERABLE_EMAIL_SQL = "users.email IS NOT NULL AND users.email ~ '\\S'".freeze

    def self.lookback_days
      ReminderSetting.lookback_days_for(REMINDER_KEY) || DEFAULT_LOOKBACK_DAYS
    end

    def self.window(now: Time.current)
      (now - lookback_days.days)..now
    end

    def self.due(now: Time.current)
      ids = []
      candidates(now: now).find_each { |user| ids << user.id if due?(user, now: now) }
      User.where(id: ids).order(:full_name)
    end

    def self.count_due(now: Time.current)
      due(now: now).count
    end

    # Everyone the window covers, including members already reminded about every visit in it.
    def self.total_accessed_in_window(now: Time.current)
      User.non_service_accounts
          .non_legacy
          .where(membership_state: 'inactive_member')
          .where(DELIVERABLE_EMAIL_SQL)
          .where(id: user_ids_with_access_in_window(now: now))
          .count
    end

    def self.due?(user, now: Time.current)
      return false if user.service_account?
      return false if user.email.blank?
      return false unless user.membership_state == 'inactive_member'
      return false if user.cancellation_on_file?
      return false if pending_reminder_mail?(user)

      unnotified_access_logs(user, now: now).exists?
    end

    def self.unnotified_access_logs(user, now: Time.current)
      AccessLog.where(user_id: user.id, logged_at: window(now: now)).lapsed_access_unnotified
    end

    def self.unnotified_access_log_ids(user, now: Time.current)
      unnotified_access_logs(user, now: now).order(:logged_at).pluck(:id)
    end

    # Visit counts for the due list, keyed by user id, in one query rather than per row.
    def self.unnotified_access_counts(user_ids, now: Time.current)
      return {} if user_ids.blank?

      AccessLog.where(user_id: user_ids, logged_at: window(now: now))
               .lapsed_access_unnotified
               .group(:user_id)
               .count
    end

    def self.candidates(now: Time.current)
      User.non_service_accounts
          .non_legacy
          .where(membership_state: 'inactive_member')
          .where(DELIVERABLE_EMAIL_SQL)
          .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
          .where(id: user_ids_with_unnotified_access(now: now))
          .then { |relation| Notifications::EligibilityOptOuts.user_scope_excluding_opt_outs(relation, REMINDER_KEY) }
    end

    def self.user_ids_with_unnotified_access(now: Time.current)
      AccessLog.where.not(user_id: nil)
               .where(logged_at: window(now: now))
               .lapsed_access_unnotified
               .distinct
               .pluck(:user_id)
    end

    def self.user_ids_with_access_in_window(now: Time.current)
      AccessLog.where.not(user_id: nil)
               .where(logged_at: window(now: now))
               .distinct
               .pluck(:user_id)
    end

    def self.pending_reminder_mail?(user)
      QueuedMail.exists?(recipient: user, mailer_action: 'lapsed_access_reminder',
                         status: %w[pending approved], sent_at: nil)
    end
  end
end
