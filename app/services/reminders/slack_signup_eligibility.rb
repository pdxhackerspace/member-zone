module Reminders
  # Active members without a linked Slack account.
  #
  # The cadence is counted from the day the membership was approved and lives on the reminder's
  # settings row; this service only decides who is still missing Slack. The account age cutoff
  # is a separate judgement from the cadence: someone who joined years ago and never wanted
  # Slack is not going to be persuaded now, however few reminders they have had.
  class SlackSignupEligibility
    extend Cadence

    REMINDER_KEY = 'slack_signup'.freeze

    APPROVAL_ANCHOR_SQL = <<~SQL.squish
      COALESCE(
        (SELECT MAX(membership_applications.reviewed_at)
         FROM membership_applications
         WHERE membership_applications.user_id = users.id
           AND membership_applications.status = 'approved'),
        users.created_at
      )
    SQL

    WITHOUT_PENDING_REMINDER_MAIL_SQL = <<~SQL.squish
      NOT EXISTS (
        SELECT 1
        FROM queued_mails
        WHERE queued_mails.recipient_id = users.id
          AND queued_mails.mailer_action IN ('slack_signup_reminder', 'slack_signup_nag')
          AND queued_mails.status IN ('pending', 'approved')
          AND queued_mails.sent_at IS NULL
      )
    SQL

    DELIVERABLE_EMAIL_SQL = "users.email IS NOT NULL AND users.email ~ '\\S'".freeze

    def self.reminder_key
      REMINDER_KEY
    end

    def self.anchor(user)
      user.membership_approved_at
    end

    def self.due(now: Time.current)
      ids = []
      candidates(now: now).find_each { |user| ids << user.id if due?(user, now: now) }
      User.where(id: ids).order(:full_name)
    end

    def self.count_due(now: Time.current)
      due(now: now).count
    end

    def self.total_without_slack(now: Time.current)
      base_scope(now: now).count
    end

    def self.active_without_slack_scope(now: Time.current)
      base_scope(now: now)
    end

    def self.candidates(now: Time.current)
      scope = base_scope(now: now)
              .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
              .then { |relation| Notifications::EligibilityOptOuts.user_scope_excluding_opt_outs(relation, REMINDER_KEY) }

      DeliveryScope.candidates(scope, key: REMINDER_KEY, anchor_sql: APPROVAL_ANCHOR_SQL, now: now)
                   .order(:full_name)
    end

    def self.due?(user, now: Time.current)
      return false unless base_user?(user, now: now)
      return false if pending_reminder_mail?(user)

      cadence_due?(user, now: now)
    end

    def self.pending_reminder_mail?(user)
      QueuedMail.exists?(recipient: user, mailer_action: %w[slack_signup_reminder slack_signup_nag],
                         status: %w[pending approved], sent_at: nil)
    end

    def self.within_account_age?(user, now: Time.current)
      user.membership_approved_at >= account_age_cutoff(now: now)
    end

    def self.account_age_cutoff(now: Time.current)
      now - MembershipSetting.slack_signup_reminder_max_account_age_months.months
    end

    def self.base_scope(now: Time.current)
      within_account_age(
        User.active
            .non_service_accounts
            .where.missing(:slack_user)
            .where(slack_id: [nil, ''])
            .where(slack_handle: [nil, ''])
            .where(DELIVERABLE_EMAIL_SQL),
        now: now
      )
    end

    def self.base_user?(user, now: Time.current)
      user.active? &&
        !user.service_account? &&
        lacks_slack_identity?(user) &&
        user.email.present? &&
        within_account_age?(user, now: now)
    end

    def self.lacks_slack_identity?(user)
      user.slack_user.blank? && user.slack_id.blank? && user.slack_handle.blank?
    end

    def self.within_account_age(relation, now: Time.current)
      relation.where("#{APPROVAL_ANCHOR_SQL} >= ?", account_age_cutoff(now: now))
    end

    private_class_method :base_scope, :base_user?, :lacks_slack_identity?, :within_account_age
  end
end
