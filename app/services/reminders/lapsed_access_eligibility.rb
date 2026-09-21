module Reminders
  # Inactive members with building access they have not been reminded about yet.
  #
  # The window looks back +ReminderSetting#lookback_days+ from now. Eligibility is driven by
  # access log entries rather than by a per-member timestamp: one reminder stamps every entry in
  # the window, so a member who badged in six times is emailed once, and only a genuinely new
  # entry makes them due again on a later run.
  #
  # The cadence sits on top of that trigger rather than replacing it. Its anchor is the oldest
  # visit we have not mentioned yet, so the start offset delays the first digest after a lapsed
  # member turns up. Each new batch of visits is a new anchor and so a fresh sequence, which is
  # why this reminder has no maximum — a member who keeps badging in keeps hearing about it, and
  # why the interval rarely comes into play: a batch is stamped as soon as it is described.
  class LapsedAccessEligibility
    extend Cadence

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

    def self.reminder_key
      REMINDER_KEY
    end

    # The oldest visit in the window that no reminder has mentioned. Nil when there is nothing
    # to say, which Schedule reads as nothing being due.
    def self.anchor(user, now: Time.current)
      unnotified_access_logs(user, now: now).minimum(:logged_at)
    end

    # The anchor for a reminder that named specific visits. Mail held for review describes the
    # visits it was written about, not whatever the window covers on the day it finally sends.
    def self.anchor_for_access_logs(access_log_ids)
      return nil if access_log_ids.blank?

      AccessLog.where(id: access_log_ids).minimum(:logged_at)
    end

    def self.record_delivery!(user, at: Time.current, access_log_ids: nil)
      anchor = anchor_for_access_logs(access_log_ids) || anchor(user, now: at)
      ReminderDelivery.record!(REMINDER_KEY, user, anchor: anchor, at: at)
    end

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

    # A cancellation on file is deliberately not a reason to stay quiet. Somebody who cancelled
    # and stopped coming has no access logs and never reaches this point anyway; somebody who
    # cancelled and is still badging in is exactly who the reminder is for.
    def self.due?(user, now: Time.current)
      return false if user.service_account?
      return false if user.email.blank?
      return false unless user.membership_state == 'inactive_member'
      return false if pending_reminder_mail?(user)

      schedule.due?(user, anchor: anchor(user, now: now), now: now)
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
      scope = User.non_service_accounts
                  .non_legacy
                  .where(membership_state: 'inactive_member')
                  .where(DELIVERABLE_EMAIL_SQL)
                  .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
                  .where(id: user_ids_with_unnotified_access(now: now))
                  .then { |relation| Notifications::EligibilityOptOuts.user_scope_excluding_opt_outs(relation, REMINDER_KEY) }

      DeliveryScope.candidates(scope, key: REMINDER_KEY, anchor_sql: anchor_sql(now: now), now: now)
    end

    # anchor in SQL, so a member whose next batch of visits arrived sooner than the interval is
    # still a candidate: a new batch is a new sequence, and the interval does not hold it back.
    def self.anchor_sql(now: Time.current)
      range = window(now: now)

      ActiveRecord::Base.sanitize_sql_array(
        [
          <<~SQL.squish,
            (SELECT MIN(access_logs.logged_at) FROM access_logs
              WHERE access_logs.user_id = users.id
                AND access_logs.lapsed_access_reminder_sent_at IS NULL
                AND access_logs.logged_at BETWEEN ? AND ?)
          SQL
          range.begin, range.end
        ]
      )
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
