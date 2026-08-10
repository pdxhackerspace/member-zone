require 'test_helper'

# Members turn up in ways that tell us nothing about whether they pay: a Slack account, a
# name on an unmatched badge scan, the first screen of the onboarding wizard. The
# "Inactive synced as active" switch decides whether that ignorance costs them access.
class UserInitialMembershipStateTest < ActiveSupport::TestCase
  test 'the benefit of the doubt gives them the onboarding window' do
    DefaultSetting.instance.update!(authentik_sync_inactive_as_active: true)

    assert_equal 'new_member', User.initial_membership_state
  end

  test 'with the switch off nothing paying for them means inactive' do
    DefaultSetting.instance.update!(authentik_sync_inactive_as_active: false)

    assert_equal 'inactive_member', User.initial_membership_state
  end

  test 'a discovered member is never left undetermined' do
    [true, false].each do |setting|
      DefaultSetting.instance.update!(authentik_sync_inactive_as_active: setting)
      user = User.create!(authentik_id: "discovered-#{SecureRandom.hex(4)}", full_name: 'Discovered',
                          payment_type: 'unknown', membership_state: User.initial_membership_state)

      assert_not_equal 'unknown', user.membership_state
    end
  end

  test 'the onboarding window closes on its own' do
    DefaultSetting.instance.update!(authentik_sync_inactive_as_active: true)
    MembershipSetting.instance.update!(new_member_expiry_days: 90)
    user = User.create!(authentik_id: "expiring-#{SecureRandom.hex(4)}", full_name: 'Expiring',
                        payment_type: 'unknown', membership_state: User.initial_membership_state)
    user.update_columns(membership_state_entered_at: 91.days.ago)

    assert_equal 'inactive_member', user.reload.effective_membership_state
  end
end
