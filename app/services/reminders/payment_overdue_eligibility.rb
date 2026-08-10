module Reminders
  # Who should hear that their dues are past due.
  #
  # Only members in overdue_member qualify. Members who told us they were leaving are in
  # cancelled_member and are deliberately left alone — chasing someone for a payment they
  # already cancelled is the main thing this reminder must not do. Members who have
  # already fallen inactive are not chased either; that conversation is reactivation.
  class PaymentOverdueEligibility
    WITHOUT_PENDING_REMINDER_MAIL_SQL = <<~SQL.squish
      NOT EXISTS (
        SELECT 1
        FROM queued_mails
        WHERE queued_mails.recipient_id = users.id
          AND queued_mails.mailer_action = 'payment_past_due'
          AND queued_mails.status IN ('pending', 'approved')
          AND queued_mails.sent_at IS NULL
      )
    SQL

    DELIVERABLE_EMAIL_SQL = "users.email IS NOT NULL AND users.email ~ '\\S'".freeze

    def self.due(now: Time.current)
      base_scope
        .where('payment_overdue_reminder_sent_at IS NULL OR payment_overdue_reminder_sent_at <= ?',
               repeat_cutoff(now: now))
        .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
        .order(:full_name)
    end

    def self.count_due(now: Time.current)
      due(now: now).count
    end

    def self.total_overdue
      base_scope.count
    end

    def self.due?(user, now: Time.current)
      return false unless base_user?(user)
      return false if pending_reminder_mail?(user)

      user.payment_overdue_reminder_sent_at.nil? || user.payment_overdue_reminder_sent_at <= repeat_cutoff(now: now)
    end

    def self.pending_reminder_mail?(user)
      QueuedMail.exists?(recipient: user, mailer_action: 'payment_past_due', status: %w[pending approved], sent_at: nil)
    end

    def self.repeat_cutoff(now: Time.current)
      now - MembershipSetting.payment_overdue_reminder_repeat_days.days
    end

    def self.base_scope
      User.non_service_accounts
          .where(membership_state: 'overdue_member')
          .where(DELIVERABLE_EMAIL_SQL)
    end

    # Reads the resolved state rather than the column: a member whose overdue grace ran
    # out is on their way to inactive and should not get one last nag.
    def self.base_user?(user)
      !user.service_account? &&
        user.email.present? &&
        user.effective_membership_state == 'overdue_member'
    end

    private_class_method :base_scope, :base_user?
  end
end
