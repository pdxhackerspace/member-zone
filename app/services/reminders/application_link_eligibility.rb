module Reminders
  class ApplicationLinkEligibility
    WITHOUT_PENDING_REMINDER_MAIL_SQL = <<~SQL.squish
      NOT EXISTS (
        SELECT 1
        FROM queued_mails
        WHERE queued_mails.mailer_action = 'application_link_reminder'
          AND queued_mails.status IN ('pending', 'approved')
          AND queued_mails.sent_at IS NULL
          AND queued_mails.mailer_args ->> 'application_verification_id' = application_verifications.id::text
      )
    SQL

    def self.active?
      ReminderSetting.enabled?('application_link') &&
        MembershipSetting.use_builtin_membership_application?
    end

    def self.due(now: Time.current)
      due_ids = candidate_scope(now: now).filter_map { |verification| verification.id if due?(verification, now: now) }
      ApplicationVerification.where(id: due_ids).order(:created_at)
    end

    def self.count_due(now: Time.current)
      return 0 unless active?

      candidate_scope(now: now).count { |verification| due?(verification, now: now) }
    end

    def self.total_awaiting
      base_scope.count(&:awaiting_application?)
    end

    def self.due?(verification, now: Time.current)
      return false unless base_verification?(verification)
      return false if pending_reminder_mail?(verification)
      return false if Notifications::DeliveryGate.blocked?(
        mailer_action: 'application_link_reminder',
        email: verification.email
      )

      delay = MembershipSetting.application_link_reminder_delay_days.days
      max_count = MembershipSetting.application_link_reminder_max_count
      cutoff = now - delay

      verification.application_link_reminder_count < max_count &&
        reminder_anchor(verification) <= cutoff
    end

    def self.pending_reminder_mail?(verification)
      QueuedMail.exists?(
        mailer_action: 'application_link_reminder',
        status: %w[pending approved],
        sent_at: nil,
        mailer_args: { application_verification_id: verification.id }
      )
    end

    def self.base_scope
      ApplicationVerification.where('expires_at > ?', Time.current)
    end

    def self.candidate_scope(now: Time.current)
      delay = MembershipSetting.application_link_reminder_delay_days.days
      max_count = MembershipSetting.application_link_reminder_max_count
      cutoff = now - delay

      base_scope
        .where(application_link_reminder_count: ...max_count)
        .where(
          '(application_link_reminder_sent_at IS NULL AND application_verifications.created_at <= ?) OR ' \
          '(application_link_reminder_sent_at IS NOT NULL AND application_link_reminder_sent_at <= ?)',
          cutoff, cutoff
        )
        .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
        .then { |scope| Notifications::EligibilityOptOuts.verification_scope_excluding_opt_outs(scope, 'application_link') }
    end

    def self.base_verification?(verification)
      !verification.expired? &&
        verification.awaiting_application? &&
        verification.email.present?
    end

    def self.reminder_anchor(verification)
      verification.application_link_reminder_sent_at || verification.created_at
    end

    private_class_method :base_scope, :candidate_scope, :base_verification?, :reminder_anchor
  end
end
