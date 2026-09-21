module Reminders
  # Applications that have been waiting for a reviewer long enough that somebody should be
  # told. The subject of the sequence is the application; the email goes to directors rather
  # than to the applicant, which is why members cannot opt out of it.
  #
  # The cadence counts from submission, so the start offset is how long an application is
  # allowed to sit before anyone is chased about it.
  class StaleApplicationEligibility
    extend Cadence

    REMINDER_KEY = 'staff_application'.freeze
    ANCHOR_SQL = 'COALESCE(membership_applications.submitted_at, membership_applications.created_at)'.freeze

    def self.reminder_key
      REMINDER_KEY
    end

    def self.anchor(application)
      application.submitted_at || application.created_at
    end

    def self.due(now: Time.current)
      ids = []
      candidates(now: now).find_each { |application| ids << application.id if due?(application, now: now) }
      MembershipApplication.where(id: ids).newest_first
    end

    def self.count_due(now: Time.current)
      due(now: now).count
    end

    def self.total_awaiting
      MembershipApplication.naggable_pending.count
    end

    def self.due?(application, now: Time.current)
      return false unless application.status.in?(MembershipApplication::NAGGABLE_PENDING_STATUSES)

      cadence_due?(application, now: now)
    end

    def self.candidates(now: Time.current)
      DeliveryScope.candidates(MembershipApplication.naggable_pending,
                               key: REMINDER_KEY, anchor_sql: ANCHOR_SQL, now: now)
    end
  end
end
