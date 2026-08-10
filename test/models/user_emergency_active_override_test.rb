require 'test_helper'

class UserEmergencyActiveOverrideTest < ActiveSupport::TestCase
  test 'compute_active_status keeps member active when emergency override is set' do
    u = users(:one)
    u.assign_attributes(
      membership_state: 'inactive_member',
      emergency_active_override: true,
      service_account: false
    )
    u.save!
    assert u.active?
  end

  test 'compute_active_status ignores override for service accounts' do
    u = users(:one)
    u.assign_attributes(
      service_account: true,
      emergency_active_override: true,
      active: false
    )
    u.save!
    assert_not u.active?
  end

  test 'compute_active_status ignores override for banned members' do
    u = users(:one)
    u.assign_attributes(
      membership_state: 'banned_member',
      emergency_active_override: true,
      service_account: false
    )
    u.save!
    assert_not u.active?
  end

  test 'compute_active_status ignores override for deceased members' do
    u = users(:one)
    u.assign_attributes(
      membership_state: 'deceased_member',
      emergency_active_override: true,
      service_account: false
    )
    u.save!
    assert_not u.active?
  end
end
