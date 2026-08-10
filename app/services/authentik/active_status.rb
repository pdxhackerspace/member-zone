module Authentik
  module ActiveStatus
    def self.for(user)
      user.compute_membership_active || sync_inactive_as_active?
    end

    def self.sync_inactive_as_active?
      DefaultSetting.instance.authentik_sync_inactive_as_active
    end
  end
end
