module Reminders
  # People who asked for a membership application link and have not sent anything back.
  #
  # The cadence counts from the day they asked, and this is the reminder most likely to have a
  # maximum set: someone who has ignored three nudges has decided.
  class ApplicationLinkEligibility
    extend Cadence

    REMINDER_KEY = 'application_link'.freeze
    ANCHOR_SQL = 'application_verifications.created_at'.freeze

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

    def self.reminder_key
      REMINDER_KEY
    end

    def self.anchor(verification)
      verification.created_at
    end

    def self.active?
      reminder_enabled? && MembershipSetting.use_builtin_membership_application?
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

      cadence_due?(verification, now: now)
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
      scope = base_scope
              .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
              .then do |relation|
                Notifications::EligibilityOptOuts.verification_scope_excluding_opt_outs(relation, REMINDER_KEY)
              end

      DeliveryScope.candidates(scope, key: REMINDER_KEY, anchor_sql: ANCHOR_SQL, now: now)
    end

    def self.base_verification?(verification)
      !verification.expired? &&
        verification.awaiting_application? &&
        verification.email.present?
    end

    private_class_method :base_scope, :candidate_scope, :base_verification?
  end
end
