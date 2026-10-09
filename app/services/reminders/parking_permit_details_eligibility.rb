module Reminders
  # Members who took a blank parking permit from an access control device and have not recorded
  # what they parked or where.
  #
  # The cadence counts from the day the device issued the permit. It stops as soon as the permit
  # has a description and location — however they got there — or stops being active, so a member
  # who clears their project early hears nothing more.
  class ParkingPermitDetailsEligibility
    extend Cadence

    REMINDER_KEY = 'parking_permit_details'.freeze
    ANCHOR_SQL = 'parking_notices.details_requested_at'.freeze

    DELIVERABLE_USER_SQL = <<~SQL.squish
      EXISTS (
        SELECT 1 FROM users
        WHERE users.id = parking_notices.user_id
          AND users.email IS NOT NULL
          AND users.email ~ '\\S'
          AND users.membership_state NOT IN (#{MembershipState::TERMINAL_STATES.map { |s| "'#{s}'" }.join(', ')})
      )
    SQL

    def self.reminder_key
      REMINDER_KEY
    end

    def self.anchor(notice)
      notice.details_requested_at
    end

    def self.due(now: Time.current)
      ids = candidates(now: now).select { |notice| due?(notice, now: now) }.map(&:id)
      ParkingNotice.where(id: ids).includes(:user, :webhook_device).order(:details_requested_at)
    end

    def self.count_due(now: Time.current)
      candidates(now: now).count { |notice| due?(notice, now: now) }
    end

    def self.total_awaiting
      remindable_scope.count
    end

    def self.due?(notice, now: Time.current)
      return false unless notice.permit? && notice.active? && notice.awaiting_details?
      return false if notice.user.blank? || notice.user.email.blank?
      return false if MailRecipientGuard.blocked?(notice.user)

      cadence_due?(notice, now: now)
    end

    def self.candidates(now: Time.current)
      DeliveryScope.candidates(remindable_scope, key: REMINDER_KEY, anchor_sql: ANCHOR_SQL, now: now)
                   .includes(:user)
    end

    def self.remindable_scope
      ParkingNotice.permits
                   .active_notices
                   .awaiting_details
                   .where(DELIVERABLE_USER_SQL)
                   .then do |scope|
                     Notifications::EligibilityOptOuts.parking_notice_scope_excluding_opt_outs(scope, REMINDER_KEY)
                   end
    end

    private_class_method :candidates, :remindable_scope
  end
end
