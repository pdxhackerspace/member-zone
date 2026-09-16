module Reminders
  # Who should hear that their dues are past due.
  #
  # Only members in overdue_member qualify. Members who told us they were leaving are in
  # cancelled_member and are deliberately left alone — chasing someone for a payment they
  # already cancelled is the main thing this reminder must not do. Members who have
  # already fallen inactive are not chased either; that conversation is reactivation — the
  # membership_lapsed email covers it.
  #
  # Nobody hears from this reminder on the day their payment was due:
  # MembershipSetting.payment_overdue_reminder_grace_days has to pass first, which leaves
  # room for a late bank transfer or a retried card to land on its own.
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
      overdue_counts[:total]
    end

    def self.total_within_grace_period(now: Time.current)
      overdue_counts(now: now)[:within_grace]
    end

    # Every overdue member, split by whether their grace period has run out yet, in one
    # pass — the reminder page wants both numbers and each one costs a full scan.
    def self.overdue_counts(now: Time.current)
      counts = { total: 0, within_grace: 0 }
      User.non_service_accounts
          .where(membership_state: REMINDER_CANDIDATE_STATES)
          .where(DELIVERABLE_EMAIL_SQL)
          .find_each do |user|
        next unless base_user?(user)

        counts[:total] += 1
        counts[:within_grace] += 1 if within_grace_period?(user, now: now)
      end
      counts
    end

    def self.due?(user, now: Time.current)
      return false unless base_user?(user)
      return false if within_grace_period?(user, now: now)
      return false if pending_reminder_mail?(user)

      user.payment_overdue_reminder_sent_at.nil? || user.payment_overdue_reminder_sent_at <= repeat_cutoff(now: now)
    end

    # The moment the member actually fell behind, which is not the moment we noticed. A
    # member whose stored state still reads current is overdue as of the deadline that has
    # already passed; one the tick job has already moved is overdue as of when it moved them.
    def self.overdue_since(user)
      if user.membership_state == 'overdue_member'
        user.membership_state_entered_at || user.created_at
      else
        user.membership_state_expires_at || user.membership_state_entered_at || user.created_at
      end
    end

    # When the first reminder may go out. Nil when we cannot date the lapse at all, which
    # leaves the member eligible rather than silently unreachable forever.
    def self.grace_expires_at(user)
      since = overdue_since(user)
      return nil if since.blank?

      since + MembershipSetting.payment_overdue_reminder_grace_days.days
    end

    # Nobody is chased on the day their payment was due.
    def self.within_grace_period?(user, now: Time.current)
      expires_at = grace_expires_at(user)
      expires_at.present? && now < expires_at
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
          .then { |scope| Notifications::EligibilityOptOuts.user_scope_excluding_opt_outs(scope, 'payment_overdue') }
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
