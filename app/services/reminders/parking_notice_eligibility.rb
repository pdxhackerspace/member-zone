module Reminders
  # Who should receive parking permit/ticket reminder emails today.
  class ParkingNoticeEligibility
    WITHOUT_PENDING_REMINDER_MAIL_SQL = <<~SQL.squish
      NOT EXISTS (
        SELECT 1
        FROM queued_mails
        WHERE queued_mails.recipient_id = parking_notices.user_id
          AND queued_mails.mailer_action LIKE 'parking_%'
          AND queued_mails.status IN ('pending', 'approved')
          AND queued_mails.sent_at IS NULL
          AND queued_mails.mailer_args ->> 'parking_notice_id' = parking_notices.id::text
      )
    SQL

    DELIVERABLE_USER_SQL = <<~SQL.squish
      parking_notices.user_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM users
        WHERE users.id = parking_notices.user_id
          AND users.email IS NOT NULL
          AND users.email ~ '\\S'
      )
    SQL

    def self.due(now: Time.current)
      ids = []
      remindable_scope.find_each { |notice| ids << notice.id if due?(notice, now: now) }
      ParkingNotice.where(id: ids).includes(:user).order(:expires_at)
    end

    def self.count_due(now: Time.current)
      due(now: now).count
    end

    def self.total_awaiting
      remindable_scope.count
    end

    def self.due?(notice, now: Time.current)
      return false unless remindable?(notice)

      pre_expiration_due?(notice, now: now) ||
        expiration_due?(notice, now: now) ||
        final_due?(notice, now: now) ||
        overdue_repeat_due?(notice, now: now)
    end

    def self.remindable?(notice)
      !notice.cleared? && notice.user.present? && notice.user.email.present? && !pending_reminder_mail?(notice)
    end

    def self.pre_expiration_due?(notice, now: Time.current)
      return false if MembershipSetting.parking_notice_reminder_days_before_expiration.zero?
      return false unless notice.active?
      return false if notice.pre_expiration_reminder_sent_at.present?
      return false if notice.expires_at <= now

      notice.expires_at <= pre_expiration_cutoff(now: now)
    end

    def self.expiration_due?(notice, now: Time.current)
      notice.expired? && notice.expires_at <= now && notice.expiration_notice_sent_at.blank?
    end

    def self.overdue_repeat_due?(notice, now: Time.current)
      return false unless notice.expired?
      return false if notice.final_reminder_sent_at.present?
      return false if final_window_reached?(notice, now: now)
      return false if notice.expiration_notice_sent_at.blank?

      last_sent = notice.overdue_reminder_sent_at || notice.expiration_notice_sent_at
      last_sent <= repeat_cutoff(now: now)
    end

    def self.final_due?(notice, now: Time.current)
      return false unless notice.expired?
      return false if notice.final_reminder_sent_at.present?

      final_window_reached?(notice, now: now)
    end

    def self.pending_reminder_mail?(notice)
      QueuedMail.where(recipient: notice.user, status: %w[pending approved], sent_at: nil)
                .exists?(["mailer_args ->> 'parking_notice_id' = ?", notice.id.to_s])
    end

    def self.pre_expiration_cutoff(now: Time.current)
      now + MembershipSetting.parking_notice_reminder_days_before_expiration.days
    end

    def self.repeat_cutoff(now: Time.current)
      now - MembershipSetting.parking_notice_expired_reminder_repeat_days.days
    end

    def self.final_cutoff(notice)
      notice.expires_at + MembershipSetting.parking_notice_final_reminder_days_after_expiration.days
    end

    def self.final_window_reached?(notice, now: Time.current)
      final_cutoff(notice) <= now
    end

    def self.remindable_scope
      ParkingNotice.not_cleared
                   .where(status: %w[active expired])
                   .where(DELIVERABLE_USER_SQL)
                   .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
    end

    def self.due_phase(notice, now: Time.current)
      return :pre_expiration if pre_expiration_due?(notice, now: now)
      return :expiration if expiration_due?(notice, now: now)
      return :final if final_due?(notice, now: now)
      return :overdue if overdue_repeat_due?(notice, now: now)

      nil
    end

    private_class_method :final_cutoff, :final_window_reached?
  end
end
