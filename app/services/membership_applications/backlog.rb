module MembershipApplications
  # Counts the applications still waiting on a decision, split the way the admin dashboard's
  # backlog bar draws them: open and recent, open and overdue, and held for review. The three
  # together are exactly MembershipApplication.pending.
  class Backlog
    AGES = %w[recent overdue].freeze

    attr_reader :recent, :overdue, :held, :overdue_days

    def self.call(now: Time.current)
      new(now:)
    end

    def initialize(now: Time.current)
      @overdue_days = MembershipSetting.application_backlog_overdue_days
      cutoff = now - @overdue_days.days
      @recent = MembershipApplication.submitted_within(cutoff).count
      @overdue = MembershipApplication.submitted_before(cutoff).count
      @held = MembershipApplication.under_review_apps.count
    end

    def total
      recent + overdue + held
    end

    def empty?
      total.zero?
    end

    # Narrows a scope of open applications to one side of the overdue cutoff.
    def self.filter_by_age(scope, age, now: Time.current)
      cutoff = now - MembershipSetting.application_backlog_overdue_days.days
      case age
      when 'recent' then scope.submitted_within(cutoff)
      when 'overdue' then scope.submitted_before(cutoff)
      else scope
      end
    end
  end
end
