module Reminders
  # Who should receive parking permit/ticket reminder emails today.
  #
  # One sequence per notice, counted from the day it expires. The start offset is negative, so
  # the first reminder is a warning that goes out before expiration; the rest follow at the
  # configured interval afterwards.
  #
  # Which of the four emails a notice gets is decided by where the send falls in that sequence
  # rather than by a phase of its own — see phase_for. The last send in the sequence is the
  # final notice, which means this is the one reminder that wants a maximum set: without one
  # there is no last send and the final notice never goes out.
  class ParkingNoticeEligibility
    extend Cadence

    REMINDER_KEY = 'parking_notices'.freeze
    ANCHOR_SQL = 'parking_notices.expires_at'.freeze

    REMINDER_MAILER_ACTIONS = %w[
      parking_permit_expiring_soon parking_ticket_expiring_soon
      parking_permit_expired parking_ticket_expired
      parking_permit_overdue_reminder parking_ticket_overdue_reminder
      parking_permit_final_reminder parking_ticket_final_reminder
    ].freeze

    REMINDER_MAILER_ACTIONS_SQL = REMINDER_MAILER_ACTIONS.map { |action| "'#{action}'" }.join(', ').freeze
    TERMINAL_MEMBERSHIP_STATES_SQL = MembershipState::TERMINAL_STATES.map { |state| "'#{state}'" }.join(', ').freeze

    WITHOUT_PENDING_REMINDER_MAIL_SQL = <<~SQL.squish
      NOT EXISTS (
        SELECT 1
        FROM queued_mails
        WHERE queued_mails.recipient_id = parking_notices.user_id
          AND queued_mails.mailer_action IN (#{REMINDER_MAILER_ACTIONS_SQL})
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
          AND users.membership_state NOT IN (#{TERMINAL_MEMBERSHIP_STATES_SQL})
      )
    SQL

    def self.reminder_key
      REMINDER_KEY
    end

    def self.anchor(notice)
      notice.expires_at
    end

    def self.due(now: Time.current)
      ids = []
      candidates(now: now).find_each { |notice| ids << notice.id if due?(notice, now: now) }
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

      cadence_due?(notice, now: now)
    end

    def self.remindable?(notice)
      return false if notice.cleared?
      return false if notice.user.blank? || notice.user.email.blank?
      return false if MailRecipientGuard.blocked?(notice.user)
      return false if pending_reminder_mail?(notice)

      true
    end

    # Which of the four emails this send is. Before expiration it is the warning; the first
    # send after expiration says the notice has expired; the last send in the sequence is the
    # final notice; everything in between is a follow-up.
    #
    # Nil when no reminder is coming, so a caller that has not checked due? cannot send the
    # wrong email by accident.
    def self.phase_for(notice, now: Time.current)
      return nil unless due?(notice, now: now)
      return :pre_expiration if now < notice.expires_at
      return :final if schedule.final_send?(notice, anchor: anchor(notice))

      last_sent_at = schedule.last_sent_at(notice, anchor: anchor(notice))
      return :expiration if last_sent_at.nil? || last_sent_at < notice.expires_at

      :overdue
    end

    def self.pending_reminder_mail?(notice)
      QueuedMail.where(
        recipient: notice.user,
        status: %w[pending approved],
        sent_at: nil,
        mailer_action: REMINDER_MAILER_ACTIONS
      ).exists?(["mailer_args ->> 'parking_notice_id' = ?", notice.id.to_s])
    end

    def self.candidates(now: Time.current)
      DeliveryScope.candidates(remindable_scope, key: REMINDER_KEY, anchor_sql: ANCHOR_SQL, now: now)
                   .order(:expires_at)
    end

    def self.remindable_scope
      ParkingNotice.not_cleared
                   .where(status: %w[active expired])
                   .where(DELIVERABLE_USER_SQL)
                   .where(WITHOUT_PENDING_REMINDER_MAIL_SQL)
                   .then do |scope|
                     Notifications::EligibilityOptOuts.parking_notice_scope_excluding_opt_outs(scope, REMINDER_KEY)
                   end
    end
  end
end
