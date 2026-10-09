module Reminders
  # Blank parking permits an access control device issued whose details nobody has recorded yet.
  #
  # The cadence counts from the day the device issued the permit. It stops as soon as the permit
  # has a description and location — however they got there — or stops being active, so a member
  # who clears their project early hears nothing more. Every member on the permit who can be
  # emailed is reminded, each with a link of their own.
  class ParkingPermitDetailsEligibility
    extend Cadence

    REMINDER_KEY = 'parking_permit_details'.freeze
    ANCHOR_SQL = 'parking_notices.details_requested_at'.freeze
    TERMINAL_MEMBERSHIP_STATES_SQL = MembershipState::TERMINAL_STATES.map { |state| "'#{state}'" }.join(', ').freeze

    def self.reminder_key
      REMINDER_KEY
    end

    def self.anchor(notice)
      notice.details_requested_at
    end

    def self.due(now: Time.current)
      ids = candidates(now: now).select { |notice| due?(notice, now: now) }.map(&:id)
      ParkingNotice.where(id: ids).includes(:members, :webhook_device).order(:details_requested_at)
    end

    def self.count_due(now: Time.current)
      candidates(now: now).count { |notice| due?(notice, now: now) }
    end

    def self.total_awaiting
      remindable_scope.count
    end

    def self.due?(notice, now: Time.current)
      return false unless notice.permit? && notice.active? && notice.awaiting_details?
      return false if recipients(notice).empty?

      cadence_due?(notice, now: now)
    end

    # The members on the permit this reminder can reach.
    def self.recipients(notice)
      notice.members.select { |member| deliverable?(member) }
    end

    def self.deliverable?(member)
      return false if member.email.blank? || MailRecipientGuard.blocked?(member)
      return false if MembershipState::TERMINAL_STATES.include?(member.membership_state)

      !Notifications::DeliveryGate.blocked?(mailer_action: 'parking_permit_details_reminder', user: member)
    end

    def self.candidates(now: Time.current)
      DeliveryScope.candidates(remindable_scope, key: REMINDER_KEY, anchor_sql: ANCHOR_SQL, now: now)
                   .includes(:members)
    end

    def self.remindable_scope
      ParkingNotice.permits.active_notices.awaiting_details.where(deliverable_member_exists_sql)
    end

    # Loose on purpose, like every candidate scope: opt-outs are left to deliverable?, which
    # checks the member's own preferences exactly.
    def self.deliverable_member_exists_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1
          FROM parking_notice_members pnm
          INNER JOIN users ON users.id = pnm.user_id
          WHERE pnm.parking_notice_id = parking_notices.id
            AND users.email IS NOT NULL
            AND users.email ~ '\\S'
            AND users.membership_state NOT IN (#{TERMINAL_MEMBERSHIP_STATES_SQL})
        )
      SQL
    end

    private_class_method :deliverable?, :candidates, :remindable_scope, :deliverable_member_exists_sql
  end
end
