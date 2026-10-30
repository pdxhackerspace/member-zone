require 'test_helper'

# The payment and cancellation rules in MembershipPayments: a cancelled member keeps access
# until their paid-through date, goes inactive after it, and comes back only for a payment
# made after they cancelled.
class MembershipPaymentsTest < ActiveSupport::TestCase
  NOW = Time.zone.local(2026, 10, 28, 12, 0, 0)

  test 'an inactive member is not projected as paying' do
    user = member(state: 'inactive_member')

    assert_equal 'inactive', user.membership_status
    assert_not user.paying?
  end

  test 'a cancelled member who expires is inactive, not paying' do
    travel_to NOW do
      user = cancelled_member(cancelled_at: 40.days.ago, dues_due_at: 2.days.ago)

      user.expire_membership_state!

      user.reload
      assert_equal 'inactive_member', user.membership_state
      assert_equal 'inactive', user.membership_status
      assert_predicate user, :cancellation_recorded?
    end
  end

  test 'a charge after the cancellation brings a cancelled member back' do
    travel_to NOW do
      user = cancelled_member(cancelled_at: 3.days.ago, dues_due_at: 20.days.from_now)

      updates = user.apply_payment_updates({ time: 1.hour.ago, amount: 50 }, first_seen: true)
      user.update!(updates)

      user.reload
      assert_equal 'current_member', user.membership_state
      assert_not_predicate user, :cancellation_recorded?
    end
  end

  test 'a charge before the cancellation leaves a cancelled member cancelled' do
    travel_to NOW do
      user = cancelled_member(cancelled_at: 1.day.ago, dues_due_at: 20.days.from_now)

      updates = user.apply_payment_updates({ time: 10.days.ago, amount: 50 }, first_seen: true)
      user.update!(updates)

      user.reload
      assert_equal 'cancelled_member', user.membership_state
      assert_equal 10.days.ago.to_date, user.last_payment_date
    end
  end

  # The renewal a member cancels straight after is the common case on the cancellation day.
  test 'a charge earlier on the cancellation day does not bring them back, a later one does' do
    travel_to NOW do
      user = cancelled_member(cancelled_at: 2.hours.ago, dues_due_at: 20.days.from_now)

      assert_not user.payment_revives?(3.hours.ago, first_seen: true)
      assert user.payment_revives?(1.hour.ago, first_seen: true)
    end
  end

  test 'a cash payment dated on the cancellation day brings them back' do
    travel_to NOW do
      user = cancelled_member(cancelled_at: 2.hours.ago, dues_due_at: 20.days.from_now)

      assert user.payment_revives?(Date.current)
      assert_not user.payment_revives?(Date.yesterday)
    end
  end

  # Nothing clears the stamp but a return, so a payment after it was never acted on.
  test 'a payment after the cancellation revives an inactive member even when re-read' do
    travel_to NOW do
      user = cancelled_member(cancelled_at: 30.days.ago, dues_due_at: 20.days.ago)
      user.update_columns(membership_state: 'inactive_member', membership_state_entered_at: 20.days.ago)

      assert user.reload.payment_revives?(25.days.ago)
    end
  end

  test 'a re-read payment from before the cancellation does not revive an inactive member' do
    travel_to NOW do
      user = cancelled_member(cancelled_at: 30.days.ago, dues_due_at: 20.days.ago)
      user.update_columns(membership_state: 'inactive_member', membership_state_entered_at: 20.days.ago)

      assert_not user.reload.record_payment!(paid_at: 35.days.ago, last_payment_date: 35.days.ago.to_date)
      assert_equal 'inactive_member', user.reload.membership_state
    end
  end

  # A member created by a sync enters their first state the moment the record exists, so
  # the payment that is linked a moment later always predates it.
  test 'a newly linked payment revives a member created after it was made' do
    travel_to NOW do
      user = member(state: 'inactive_member')

      updates = user.apply_payment_updates({ time: 3.days.ago, amount: 50 }, first_seen: true)

      assert_equal 'current_member', updates[:membership_state]
    end
  end

  test 'a re-read payment from before state entry is not news' do
    travel_to NOW do
      user = member(state: 'inactive_member')

      assert_not user.payment_revives?(3.days.ago)
    end
  end

  test 'a sponsored member records the payment and stays sponsored' do
    user = member(state: 'sponsored_member', is_sponsored: true, payment_type: 'sponsored')

    assert_not user.record_payment!(paid_at: Time.current, last_payment_date: Date.current)

    user.reload
    assert_equal 'sponsored_member', user.membership_state
    assert_equal Date.current, user.last_payment_date
  end

  test 'a resubscribe after cancelling brings back a member still covered' do
    travel_to NOW do
      user = cancelled_member(cancelled_at: 3.days.ago, dues_due_at: 20.days.from_now)

      assert user.record_subscription_return!(1.day.ago)
      assert_equal 'current_member', user.reload.membership_state
    end
  end

  test 'a subscription from before the cancellation is not a return' do
    travel_to NOW do
      user = cancelled_member(cancelled_at: 3.days.ago, dues_due_at: 20.days.from_now)

      assert_not user.record_subscription_return!(1.year.ago)
      assert_equal 'cancelled_member', user.reload.membership_state
    end
  end

  # They come back with the first charge on the new subscription, not before.
  test 'a resubscribe does not bring back a member who already went inactive' do
    travel_to NOW do
      user = cancelled_member(cancelled_at: 40.days.ago, dues_due_at: 10.days.ago)
      user.update_columns(membership_state: 'inactive_member', membership_state_entered_at: 10.days.ago)

      assert_not user.reload.record_subscription_return!(1.hour.ago)
      assert_equal 'inactive_member', user.reload.membership_state
    end
  end

  test 'settling a cancellation keeps a covered member cancelled' do
    travel_to NOW do
      user = member(state: 'current_member', dues_due_at: 20.days.from_now)

      assert_equal :cancelled, user.settle_cancellation!(2.days.ago)

      user.reload
      assert_equal 'cancelled_member', user.membership_state
      assert_equal 2.days.ago.to_i, user.membership_state_entered_at.to_i
    end
  end

  test 'settling an old cancellation plays it forward to inactive' do
    travel_to NOW do
      user = member(state: 'current_member', dues_due_at: 10.days.ago)

      assert_equal 'inactive_member', user.cancellation_landing_state
      assert_equal :cancelled, user.settle_cancellation!(40.days.ago)

      user.reload
      assert_equal 'inactive_member', user.membership_state
      assert_equal 40.days.ago.to_i, user.membership_cancelled_at.to_i
    end
  end

  test 'settling a cancellation only dates a member who already lapsed' do
    user = member(state: 'inactive_member')

    assert_equal :noted, user.settle_cancellation!(1.day.ago)

    user.reload
    assert_equal 'inactive_member', user.membership_state
    assert_predicate user, :cancellation_recorded?
  end

  test 'a cancellation does not disturb a guest or a ban' do
    %w[guest_member banned_member].each do |state|
      user = member(state: state)

      assert_equal :locked, user.settle_cancellation!(1.day.ago)
      assert_equal state, user.reload.membership_state
    end
  end

  test 'a cash return on the cancellation day counts, a timed one earlier that day does not' do
    travel_to NOW do
      cancelled_at = 2.hours.ago
      user = member(state: 'current_member', dues_due_at: 20.days.from_now)
      return_event(user, source: 'recharge', at: 3.hours.ago)

      assert_not user.returned_after?(cancelled_at)

      return_event(user, source: 'cash', at: Date.current.beginning_of_day)
      assert user.returned_after?(cancelled_at)
    end
  end

  private

  def member(state:, **attrs)
    User.create!(
      {
        authentik_id: "payments-#{SecureRandom.hex(4)}",
        full_name: 'Payments Member',
        payment_type: 'recharge',
        membership_state: state,
        membership_plan: membership_plans(:monthly_standard)
      }.merge(attrs)
    )
  end

  def cancelled_member(cancelled_at:, dues_due_at:)
    user = member(state: 'current_member', dues_due_at: dues_due_at)
    user.update_columns(membership_state: 'cancelled_member', membership_cancelled_at: cancelled_at,
                        membership_state_entered_at: cancelled_at)
    user.reload
  end

  def return_event(user, source:, at:)
    user.payment_events.create!(event_type: 'payment', source: source, amount: 50, currency: 'USD',
                                occurred_at: at, external_id: "return-#{SecureRandom.hex(4)}")
  end
end
