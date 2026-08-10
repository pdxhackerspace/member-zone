require 'test_helper'

class MembershipCleanupTest < ActiveSupport::TestCase
  test 'cleanup leaves sponsored members active even with lapsed dues' do
    user = User.create!(
      authentik_id: 'cleanup-sponsored',
      full_name: 'Cleanup Sponsored',
      membership_state: 'sponsored_member',
      is_sponsored: true,
      payment_type: 'sponsored'
    )
    user.paypal_payments.create!(
      paypal_id: 'PP-SPONSORED-OLD',
      transaction_time: 90.days.ago,
      amount: 40.0,
      currency: 'USD',
      status: 'Completed'
    )
    user.update_columns(active: false)

    MembershipCleanup.new(dry_run: false).run

    user.reload
    assert user.active?, 'sponsored members should remain active during cleanup'
    assert_equal 'sponsored_member', user.membership_state
  end
end
