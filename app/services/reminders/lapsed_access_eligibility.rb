module Reminders
  # Inactive members who badged in yesterday and have not been reminded yet today.
  class LapsedAccessEligibility
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

    def self.due(now: Time.current)
      ids = []
      candidates(now: now).find_each { |user| ids << user.id if due?(user, now: now) }
      User.where(id: ids).order(:full_name)
    end

    def self.count_due(now: Time.current)
      due(now: now).count
    end

    def self.total_accessed_yesterday(now: Time.current)
      candidates(now: now, include_already_reminded_today: true).count
    end

    def self.due?(user, now: Time.current)
      return false unless base_user?(user, now: now)
      return false if pending_reminder_mail?(user)
      return false if reminded_today?(user, now: now)

      accessed_yesterday?(user, now: now)
    end

    def self.yesterday_window(now: Time.current)
      (now - 1.day).to_date.all_day
    end

    def self.candidates(now: Time.current, include_already_reminded_today: false)
      scope = User.non_service_accounts
                  .non_legacy
                  .where(membership_state: 'inactive_member')
                  .where(DELIVERABLE_EMAIL_SQL)
                  .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
                  .where(id: user_ids_with_yesterday_access(now: now))
                  .then { |relation| Notifications::EligibilityOptOuts.user_scope_excluding_opt_outs(relation, 'lapsed_access') }

      unless include_already_reminded_today
        scope = scope.where('lapsed_access_reminder_sent_at IS NULL OR lapsed_access_reminder_sent_at < ?',
                            now.beginning_of_day)
      end

      scope
    end

    def self.user_ids_with_yesterday_access(now: Time.current)
      AccessLog.where.not(user_id: nil)
               .where(logged_at: yesterday_window(now: now))
               .distinct
               .pluck(:user_id)
    end

    def self.accessed_yesterday?(user, now: Time.current)
      AccessLog.exists?(user_id: user.id, logged_at: yesterday_window(now: now))
    end

    def self.reminded_today?(user, now: Time.current)
      user.lapsed_access_reminder_sent_at.present? && user.lapsed_access_reminder_sent_at >= now.beginning_of_day
    end

    def self.pending_reminder_mail?(user)
      QueuedMail.exists?(recipient: user, mailer_action: 'lapsed_access_reminder',
                         status: %w[pending approved], sent_at: nil)
    end

    def self.base_user?(user, now: Time.current)
      return false if user.service_account?
      return false if user.email.blank?
      return false unless user.membership_state == 'inactive_member'
      return false if user.cancellation_on_file?

      accessed_yesterday?(user, now: now)
    end

    private_class_method :base_user?
  end
end
