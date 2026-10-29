require 'test_helper'

module Recharge
  class SubscriptionCancellationTest < ActiveSupport::TestCase
    test 'records a cancellation and keeps the member active until paid through' do
      user = User.create!(
        authentik_id: 'recharge-cancel',
        full_name: 'Recharge Cancel',
        membership_state: 'current_member',
        last_payment_date: 5.days.ago.to_date,
        payment_type: 'recharge'
      )
      subscription = {
        recharge_subscription_id: '12345',
        customer_id: '999',
        email: user.email,
        product_title: 'Monthly',
        price: 40.0,
        cancelled_at: 1.hour.ago
      }

      assert_equal :cancelled, SubscriptionCancellation.call(user: user, subscription: subscription, source: 'test')

      user.reload
      assert_equal 'cancelled_member', user.membership_state
      assert user.active?
      assert_equal 1, user.payment_events.where(event_type: 'subscription_cancelled').count
      assert_equal 1, user.journals.where(action: 'subscription_cancelled').count
    end

    test 'a cancelled member missing the date gets it noted without moving' do
      user = User.create!(
        authentik_id: 'recharge-cancelled',
        full_name: 'Already Cancelled',
        membership_state: 'cancelled_member',
        payment_type: 'recharge'
      )

      assert_equal :noted,
                   SubscriptionCancellation.call(user: user, subscription: { 'id' => '12345' }, source: 'test')

      user.reload
      assert_equal 'cancelled_member', user.membership_state
      assert_predicate user, :cancellation_recorded?
      assert_equal 1, user.payment_events.where(event_type: 'subscription_cancelled').count
    end

    # The subscription really did end at Recharge, so the event is worth keeping; a ban or
    # a death is not something a billing notice gets to undo.
    test 'a cancellation for a banned member is filed without moving them' do
      user = User.create!(
        authentik_id: 'recharge-cancel-banned',
        full_name: 'Banned Cancel',
        membership_state: 'banned_member',
        payment_type: 'recharge'
      )
      subscription = { recharge_subscription_id: '777', product_title: 'Monthly', price: 40.0 }

      assert_equal :state_locked,
                   SubscriptionCancellation.call(user: user, subscription: subscription, source: 'test')

      user.reload
      assert_equal 'banned_member', user.membership_state
      assert_equal 1, user.payment_events.where(event_type: 'subscription_cancelled').count
      assert_equal 0, user.journals.where(action: 'subscription_cancelled').count
    end

    test 'a cancellation for a deceased member is filed without moving them' do
      user = User.create!(
        authentik_id: 'recharge-cancel-deceased',
        full_name: 'Deceased Cancel',
        membership_state: 'deceased_member',
        payment_type: 'recharge'
      )

      assert_equal :state_locked,
                   SubscriptionCancellation.call(user: user, subscription: { 'id' => '888' }, source: 'test')

      assert_equal 'deceased_member', user.reload.membership_state
    end

    # inactive_member is where the cancellation would have put them anyway, so nothing moves
    # — but the date is the only thing that tells them apart from a member who quietly
    # stopped paying, and the lapse email reads it. Membership::CancellationReconciler exists
    # to stamp these; a live notice must not leave one behind for it to find.
    test 'a cancellation for a lapsed member records the date without moving them' do
      user = User.create!(
        authentik_id: 'recharge-cancel-inactive',
        full_name: 'Lapsed Cancel',
        membership_state: 'inactive_member',
        payment_type: 'recharge'
      )
      cancelled_at = 3.days.ago
      subscription = { recharge_subscription_id: '666', product_title: 'Monthly', price: 40.0,
                       cancelled_at: cancelled_at }

      assert_equal :noted, SubscriptionCancellation.call(user: user, subscription: subscription, source: 'test')

      user.reload
      assert_equal 'inactive_member', user.membership_state
      assert_equal cancelled_at.to_i, user.membership_cancelled_at.to_i
      assert_predicate user, :cancellation_recorded?
      assert_equal 1, user.payment_events.where(event_type: 'subscription_cancelled').count
      assert_equal 0, user.journals.where(action: 'subscription_cancelled').count
    end

    # The states a person chose deliberately are the ones the reconciler refuses to stamp, so
    # the live path must not stamp them either.
    test 'a cancellation for a sponsored member is filed without recording a date' do
      user = User.create!(
        authentik_id: 'recharge-cancel-sponsored',
        full_name: 'Sponsored Cancel',
        membership_state: 'sponsored_member',
        payment_type: 'sponsored'
      )
      subscription = { recharge_subscription_id: '444', product_title: 'Monthly', price: 40.0 }

      assert_equal :state_locked,
                   SubscriptionCancellation.call(user: user, subscription: subscription, source: 'test')

      user.reload
      assert_equal 'sponsored_member', user.membership_state
      assert_nil user.membership_cancelled_at
      assert_equal 1, user.payment_events.where(event_type: 'subscription_cancelled').count
    end

    test 'the member is stamped with the date they cancelled, not the date we read the notice' do
      user = User.create!(
        authentik_id: 'recharge-cancel-backdated',
        full_name: 'Backdated Cancel',
        membership_state: 'current_member',
        last_payment_date: 5.days.ago.to_date,
        payment_type: 'recharge'
      )
      cancelled_at = 2.days.ago

      SubscriptionCancellation.call(user: user, subscription: { recharge_subscription_id: '333',
                                                                cancelled_at: cancelled_at }, source: 'test')

      assert_equal cancelled_at.to_i, user.reload.membership_cancelled_at.to_i
    end

    test 'duplicate webhook deliveries do not create duplicate events' do
      user = User.create!(
        authentik_id: 'recharge-cancel-dup',
        full_name: 'Duplicate Cancel',
        membership_state: 'current_member',
        payment_type: 'recharge'
      )
      cancelled_at = Time.zone.local(2026, 10, 1, 12, 0, 0)
      subscription = { recharge_subscription_id: '555', product_title: 'Monthly', price: 40.0,
                       cancelled_at: cancelled_at }

      assert_equal :cancelled, SubscriptionCancellation.call(user: user, subscription: subscription, source: 'test')
      assert_equal :already_processed,
                   SubscriptionCancellation.call(user: user, subscription: subscription, source: 'test')

      assert_equal 1, user.payment_events.where(event_type: 'subscription_cancelled').count
    end

    test 'a second cancellation after the tick moved them inactive does not change state' do
      cancelled_at = Time.zone.local(2026, 10, 26, 18, 0, 0)
      user = User.create!(
        authentik_id: 'recharge-cancel-retick',
        full_name: 'Retick Cancel',
        membership_state: 'current_member',
        payment_type: 'recharge',
        last_payment_date: Date.new(2026, 9, 27),
        dues_due_at: Time.zone.local(2026, 10, 27, 0, 0, 0),
        membership_plan: membership_plans(:monthly_standard)
      )
      subscription = { recharge_subscription_id: 'retick', product_title: 'Monthly', price: 40.0,
                       cancelled_at: cancelled_at }

      travel_to cancelled_at do
        assert_equal :cancelled, SubscriptionCancellation.call(user: user, subscription: subscription, source: 'test')
      end

      travel_to Time.zone.local(2026, 10, 27, 4, 0, 0) do
        Membership::TickJob.new.perform
      end

      user.reload
      assert_equal 'inactive_member', user.membership_state
      entered_at = user.membership_state_entered_at
      stamp = user.membership_cancelled_at

      travel_to Time.zone.local(2026, 10, 27, 12, 0, 0) do
        assert_equal :already_processed,
                     SubscriptionCancellation.call(user: user, subscription: subscription, source: 'test')
      end

      user.reload
      assert_equal 'inactive_member', user.membership_state
      assert_equal stamp.to_i, user.membership_cancelled_at.to_i
      assert_equal entered_at.to_i, user.membership_state_entered_at.to_i
    end

    test 'a cancellation older than a later subscription start is superseded' do
      user = User.create!(
        authentik_id: 'recharge-cancel-superseded',
        full_name: 'Superseded Cancel',
        membership_state: 'current_member',
        payment_type: 'recharge',
        last_payment_date: 40.days.ago.to_date,
        dues_due_at: 1.month.from_now
      )
      PaymentEvent.create!(
        user: user,
        event_type: 'subscription_started',
        source: 'recharge',
        occurred_at: 1.day.ago,
        external_id: 'recharge-sub-new-subscription_started',
        amount: 40,
        currency: 'USD'
      )

      assert_equal :superseded, SubscriptionCancellation.call(
        user: user,
        subscription: { recharge_subscription_id: 'old-sub', cancelled_at: 10.days.ago },
        source: 'test'
      )

      user.reload
      assert_equal 'current_member', user.membership_state
      assert_nil user.membership_cancelled_at
      assert_equal 1, user.payment_events.where(event_type: 'subscription_cancelled').count
    end
  end
end
