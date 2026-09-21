module Reminders
  # Who should hear that their dues are past due.
  #
  # Only members in overdue_member qualify. Members who told us they were leaving are in
  # cancelled_member and are deliberately left alone — chasing someone for a payment they
  # already cancelled is the main thing this reminder must not do. Members who have
  # already fallen inactive are not chased either; that conversation is reactivation — the
  # membership_lapsed email covers it.
  #
  # The cadence counts from the moment the member actually fell behind, so the reminder's
  # start offset is what used to be called its grace period: nobody hears from it on the day
  # their payment was due, which leaves room for a late bank transfer or a retried card to
  # land on its own. A member who pays up and falls behind again has a new anchor, so they
  # start at the first reminder rather than wherever the last sequence left off.
  class PaymentOverdueEligibility
    extend Cadence

    REMINDER_KEY = 'payment_overdue'.freeze

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

    # A rough anchor in SQL, so a member starting a fresh overdue spell is picked up as a
    # candidate even though their last reminder was only days ago.
    #
    # overdue_since resolves a deadline in Ruby for members whose stored state has not caught
    # up yet, which no column holds. This stands in for it: when the two disagree the row is
    # let through as a candidate and due? settles it, which is the safe direction to be wrong.
    APPROXIMATE_ANCHOR_SQL = 'COALESCE(users.membership_state_entered_at, users.created_at)'.freeze

    def self.reminder_key
      REMINDER_KEY
    end

    def self.anchor(user)
      overdue_since(user)
    end

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

    # Every overdue member, split by whether their first reminder is due yet, in one pass —
    # the reminder page wants both numbers and each one costs a full scan.
    def self.overdue_counts(now: Time.current)
      counts = { total: 0, within_grace: 0 }
      offset_days = schedule.start_offset_days
      User.non_service_accounts
          .where(membership_state: REMINDER_CANDIDATE_STATES)
          .where(DELIVERABLE_EMAIL_SQL)
          .find_each do |user|
        next unless base_user?(user)

        counts[:total] += 1
        counts[:within_grace] += 1 if within_grace_period?(user, now: now, offset_days: offset_days)
      end
      counts
    end

    def self.due?(user, now: Time.current)
      return false unless base_user?(user)
      return false if pending_reminder_mail?(user)

      cadence_due?(user, now: now)
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

    # When the first reminder may go out: the reminder's start offset from the lapse. Nil when
    # we cannot date the lapse at all, which leaves the member eligible rather than silently
    # unreachable forever.
    def self.grace_expires_at(user, offset_days: nil)
      since = overdue_since(user)
      return nil if since.blank?

      since + (offset_days || schedule.start_offset_days).days
    end

    # Nobody is chased before their start offset has elapsed. +offset_days+ lets a caller
    # counting the whole roster read the setting once rather than per member.
    def self.within_grace_period?(user, now: Time.current, offset_days: nil)
      expires_at = grace_expires_at(user, offset_days: offset_days)
      expires_at.present? && now < expires_at
    end

    def self.pending_reminder_mail?(user)
      QueuedMail.exists?(recipient: user, mailer_action: 'payment_past_due', status: %w[pending approved], sent_at: nil)
    end

    # Members whose stored state might still read current while effective resolution
    # already has them overdue. NotifyPaymentOverdue re-checks due? on each row.
    def self.candidates(now: Time.current)
      scope = User.non_service_accounts
                  .where(membership_state: REMINDER_CANDIDATE_STATES)
                  .where(DELIVERABLE_EMAIL_SQL)
                  .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
                  .then { |relation| Notifications::EligibilityOptOuts.user_scope_excluding_opt_outs(relation, REMINDER_KEY) }

      DeliveryScope.candidates(scope, key: REMINDER_KEY, anchor_sql: APPROXIMATE_ANCHOR_SQL, now: now)
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
