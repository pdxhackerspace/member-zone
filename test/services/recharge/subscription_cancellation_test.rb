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

    test 'a member who is already cancelled is left alone' do
      user = User.create!(
        authentik_id: 'recharge-cancelled',
        full_name: 'Already Cancelled',
        membership_state: 'cancelled_member',
        payment_type: 'recharge'
      )

      assert_equal :already_cancelled,
                   SubscriptionCancellation.call(user: user, subscription: { 'id' => '12345' }, source: 'test')

      assert_equal 0, user.payment_events.count
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

    test 'duplicate webhook deliveries do not create duplicate events' do
      user = User.create!(
        authentik_id: 'recharge-cancel-dup',
        full_name: 'Duplicate Cancel',
        membership_state: 'current_member',
        payment_type: 'recharge'
      )
      subscription = { recharge_subscription_id: '555', product_title: 'Monthly', price: 40.0 }

      assert_equal :cancelled, SubscriptionCancellation.call(user: user, subscription: subscription, source: 'test')
      assert_equal :already_cancelled,
                   SubscriptionCancellation.call(user: user, subscription: subscription, source: 'test')

      assert_equal 1, user.payment_events.where(event_type: 'subscription_cancelled').count
    end
  end
end
