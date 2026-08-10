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

    REMINDER_CANDIDATE_STATES = %w[current_member provisional_member overdue_member].freeze

    def self.due(now: Time.current)
      ids = []
      candidates(now: now).find_each { |user| ids << user.id if due?(user, now: now) }
      User.where(id: ids).order(:full_name)
    end

    def self.count_due(now: Time.current)
      due(now: now).count
    end

    def self.total_overdue
      count = 0
      User.non_service_accounts
          .where(membership_state: REMINDER_CANDIDATE_STATES)
          .where(DELIVERABLE_EMAIL_SQL)
          .find_each { |user| count += 1 if base_user?(user) }
      count
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

    # Members whose stored state might still read current while effective resolution
    # already has them overdue. NotifyPaymentOverdue re-checks due? on each row.
    def self.candidates(now: Time.current)
      User.non_service_accounts
          .where(membership_state: REMINDER_CANDIDATE_STATES)
          .where(DELIVERABLE_EMAIL_SQL)
          .where('payment_overdue_reminder_sent_at IS NULL OR payment_overdue_reminder_sent_at <= ?',
                 repeat_cutoff(now: now))
          .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
          .order(:full_name)
    end

    # Reads the resolved state rather than the column: a member whose overdue grace ran
    # out is on their way to inactive and should not get one last nag.
    def self.base_user?(user)
      return false if user.service_account?
      return false if user.email.blank?
      return false unless user.effective_membership_state == 'overdue_member'

      # Someone who told us they were leaving is not someone to chase for a payment,
      # whether or not the notice has been processed yet.
      !user.cancellation_on_file?
    end

    private_class_method :base_user?
  end
end
