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
