require 'test_helper'

class UserNewServiceAccountActiveTest < ActiveSupport::TestCase
  test 'a new service account starts active' do
    user = User.create!(authentik_id: 'sa-kiosk', full_name: 'Parking Kiosk', payment_type: 'unknown',
                        service_account: true)

    assert user.reload.active?
  end

  test 'a new service account explicitly created inactive stays inactive' do
    user = User.create!(authentik_id: 'sa-off', full_name: 'Retired Kiosk', payment_type: 'unknown',
                        service_account: true, active: false)

    assert_not user.reload.active?
  end

  test 'turning an existing inactive member into a service account does not activate it' do
    user = users(:two)
    user.update_columns(active: false, membership_state: 'inactive_member')
    user.update!(service_account: true)

    assert_not user.reload[:active]
  end

  test 'a new member is not made active by this' do
    user = User.create!(authentik_id: 'm-new', full_name: 'New Person', payment_type: 'unknown')

    assert_not user.reload[:active]
  end
end
