module Reports
  # Members whose membership was approved but who have not been through building access
  # orientation yet, whatever their dues are doing. Wider than the set the orientation
  # reminder writes to: this is the report that has to account for everyone, because
  # DuesLapsedQuery leaves untrained members off the billing list expecting to find them here.
  class AwaitingOrientationQuery < ScopeQuery
    def initialize
      super(Reminders::OrientationEligibility.awaiting_orientation_scope.order(Catalog::NAME_ORDER))
    end

    def page_locals(users)
      { approved_at: ApprovalDates.for(users) }
    end
  end
end
