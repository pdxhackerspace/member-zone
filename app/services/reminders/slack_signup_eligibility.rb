module Reminders
  class SlackSignupEligibility
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

    def self.due(now: Time.current)
      initial_cutoff = now - MembershipSetting.slack_signup_reminder_initial_delay_days.days
      repeat_cutoff = now - MembershipSetting.slack_signup_reminder_repeat_delay_days.days

      base_scope(now: now)
        .where("#{APPROVAL_ANCHOR_SQL} <= ?", initial_cutoff)
        .where('slack_signup_reminder_sent_at IS NULL OR slack_signup_reminder_sent_at <= ?', repeat_cutoff)
        .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
        .then { |scope| Notifications::EligibilityOptOuts.user_scope_excluding_opt_outs(scope, 'slack_signup') }
        .order(:full_name)
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

    def self.due?(user, now: Time.current)
      return false unless base_user?(user, now: now)
      return false if pending_reminder_mail?(user)

      initial_cutoff = now - MembershipSetting.slack_signup_reminder_initial_delay_days.days
      repeat_cutoff = now - MembershipSetting.slack_signup_reminder_repeat_delay_days.days
      anchor = user.membership_approved_at

      anchor <= initial_cutoff &&
        (user.slack_signup_reminder_sent_at.nil? || user.slack_signup_reminder_sent_at <= repeat_cutoff)
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
