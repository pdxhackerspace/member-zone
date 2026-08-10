module Reports
  # A plain scope, plus whether each member on the page can get into the building. Data
  # problems are easier to rank when you can see which of them are holding a key.
  class BuildingAccessScopeQuery < ScopeQuery
    def page_locals(users)
      { building_access: BuildingAccessStatus.for(users) }
    end
  end
end
