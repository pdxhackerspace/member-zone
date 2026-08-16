module Reports
  # Members whose membership was approved but who have not been through building access
  # orientation yet. Shares its definition with the orientation reminder, so the report and
  # the email never disagree about who is waiting.
  class AwaitingOrientationQuery < ScopeQuery
    def initialize
      super(Reminders::OrientationEligibility.awaiting_orientation_scope.order(Catalog::NAME_ORDER))
    end

    def page_locals(users)
      { approved_at: ApprovalDates.for(users) }
    end
  end
end
