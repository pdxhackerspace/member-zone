require 'test_helper'

module Authentik
  class ActiveStatusTest < ActiveSupport::TestCase
    setup do
      @settings = DefaultSetting.instance
      @original_value = @settings.authentik_sync_inactive_as_active
    end

    teardown do
      @settings.update!(authentik_sync_inactive_as_active: @original_value)
    end

    test 'returns user active status when sync inactive as active is disabled' do
      @settings.update!(authentik_sync_inactive_as_active: false)
      active_user = users(:one)
      inactive_user = users(:two)
      inactive_user.update_columns(active: false, membership_state: 'inactive_member')

      assert Authentik::ActiveStatus.for(active_user)
      assert_not Authentik::ActiveStatus.for(inactive_user)
    end

    test 'forces inactive users active when sync inactive as active is enabled' do
      @settings.update!(authentik_sync_inactive_as_active: true)
      inactive_user = users(:two)
      inactive_user.update_columns(active: false, membership_state: 'inactive_member')

      assert Authentik::ActiveStatus.for(inactive_user)
    end

    test 'keeps active users active when sync inactive as active is enabled' do
      @settings.update!(authentik_sync_inactive_as_active: true)

      assert Authentik::ActiveStatus.for(users(:one))
    end
  end
end
