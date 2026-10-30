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

  test 'cleanup does not revive a cancelled member with a payment from before they cancelled' do
    user = cancelled_member('cleanup-cancelled', cancelled_at: 2.days.ago)
    paypal_payment(user, 'PP-BEFORE-CANCEL', 5.days.ago)

    MembershipCleanup.new(dry_run: false).run

    user.reload
    assert_equal 'cancelled_member', user.membership_state
    assert_predicate user, :cancellation_recorded?
  end

  test 'cleanup revives a cancelled member who paid after cancelling' do
    user = cancelled_member('cleanup-returned', cancelled_at: 10.days.ago)
    paypal_payment(user, 'PP-AFTER-CANCEL', 2.days.ago)

    MembershipCleanup.new(dry_run: false).run

    assert_equal 'current_member', user.reload.membership_state
  end

  private

  def cancelled_member(authentik_id, cancelled_at:)
    user = User.create!(authentik_id: authentik_id, full_name: authentik_id.titleize, payment_type: 'paypal',
                        membership_state: 'current_member', dues_due_at: 20.days.from_now)
    user.update_columns(membership_state: 'cancelled_member', membership_cancelled_at: cancelled_at,
                        membership_state_entered_at: cancelled_at)
    user
  end

  def paypal_payment(user, paypal_id, at)
    PaypalPayment.insert!({ paypal_id: paypal_id, transaction_time: at, amount: 40.0, currency: 'USD',
                            status: 'Completed', user_id: user.id, created_at: Time.current, updated_at: Time.current })
  end
end
