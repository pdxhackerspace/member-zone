module Reports
  # Members behind on dues, minus anyone still waiting on their building access orientation.
  #
  # Someone who was never let into the building is not a billing problem. They belong on the
  # awaiting-orientation report, and chasing them for dues is the wrong conversation to have
  # first.
  class DuesLapsedQuery < ScopeQuery
    def initialize
      super(
        User.where(membership_state: 'overdue_member')
            .non_service_accounts
            .building_access_trained
            .order(Catalog::NAME_ORDER)
      )
    end

    def page_locals(users)
      { approved_at: ApprovalDates.for(users) }
    end
  end
end
