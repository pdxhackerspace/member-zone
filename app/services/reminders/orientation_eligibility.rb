module Reminders
  # Who still needs their building access orientation.
  #
  # new_member is precisely that state: the membership was approved and nothing has granted
  # building access yet. Recording the building access training moves a member on to
  # provisional_member, so leaving the state is how they stop being reminded.
  #
  # The training check is a backstop for members who reached new_member the long way round —
  # trained first and approved afterwards, say — where the training exists but never
  # triggered the transition.
  class OrientationEligibility
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
          AND queued_mails.mailer_action = 'orientation_reminder'
          AND queued_mails.status IN ('pending', 'approved')
          AND queued_mails.sent_at IS NULL
      )
    SQL

    DELIVERABLE_EMAIL_SQL = "users.email IS NOT NULL AND users.email ~ '\\S'".freeze

    # Everyone approved but not yet oriented, whether or not a reminder is due for them.
    # This is the list the report shows.
    def self.awaiting_orientation_scope
      User.where(membership_state: 'new_member')
          .non_service_accounts.non_legacy
          .awaiting_building_access_training
    end

    def self.total_awaiting
      awaiting_orientation_scope.count
    end

    def self.due(now: Time.current)
      cutoff = repeat_cutoff(now: now)

      awaiting_orientation_scope
        .where(DELIVERABLE_EMAIL_SQL)
        .where("#{APPROVAL_ANCHOR_SQL} <= ?", cutoff)
        .where('orientation_reminder_sent_at IS NULL OR orientation_reminder_sent_at <= ?', cutoff)
        .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
        .order(:full_name)
    end

    def self.count_due(now: Time.current)
      due(now: now).count
    end

    def self.due?(user, now: Time.current)
      return false unless base_user?(user)
      return false if pending_reminder_mail?(user)

      cutoff = repeat_cutoff(now: now)
      user.membership_approved_at <= cutoff &&
        (user.orientation_reminder_sent_at.nil? || user.orientation_reminder_sent_at <= cutoff)
    end

    def self.pending_reminder_mail?(user)
      QueuedMail.exists?(recipient: user, mailer_action: 'orientation_reminder',
                         status: %w[pending approved], sent_at: nil)
    end

    # One setting covers both halves of the cadence: how long after approval the first
    # reminder goes out, and how long between reminders after that.
    def self.repeat_cutoff(now: Time.current)
      now - MembershipSetting.orientation_reminder_repeat_days.days
    end

    # Reads the resolved state rather than the column: a member whose new-member window has
    # already run out is on their way to inactive, and booking an orientation is no longer
    # the conversation to have with them.
    def self.base_user?(user)
      return false if user.service_account? || user.legacy?
      return false if user.email.blank?
      return false unless user.effective_membership_state == 'new_member'

      !user.building_access_trained?
    end

    private_class_method :base_user?
  end
end
