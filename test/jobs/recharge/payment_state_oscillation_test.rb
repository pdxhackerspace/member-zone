require 'test_helper'

# The loop that moved a cancelled member back to paying every morning: the tick expires
# the cancellation, the payment sync re-reads the charge that was already counted, and
# the subscription sync sees the same CANCELLED row again. After the fix the member
# stays inactive, and the cancellation stamp survives.
class PaymentStateOscillationTest < ActiveSupport::TestCase
  CANCELLED_AT = Time.zone.local(2026, 10, 26, 18, 0, 0)
  PAID_ON = Time.zone.local(2026, 9, 27, 12, 0, 0)

  test 'cancel, tick, payment sync, and subscription sync leave the member inactive' do
    user = travel_to(CANCELLED_AT) { cancel_member }
    subscription = subscription_for(user)

    travel_to Time.zone.local(2026, 10, 27, 4, 0, 0) do
      Membership::TickJob.new.perform
    end
    user.reload
    assert_equal 'inactive_member', user.membership_state
    stamp = user.membership_cancelled_at

    travel_to Time.zone.local(2026, 10, 27, 6, 0, 0) do
      with_recharge_enabled do
        Recharge::PaymentSynchronizer.new(client: ChargeClient.new(charge_for(user))).call
      end
    end
    user.reload
    assert_equal 'inactive_member', user.membership_state
    assert_equal stamp.to_i, user.membership_cancelled_at.to_i

    travel_to Time.zone.local(2026, 10, 27, 12, 0, 0) do
      with_recharge_enabled do
        Recharge::SubscriptionSynchronizer.new(client: SubscriptionClient.new(subscription)).call
      end
    end

    user.reload
    assert_equal 'inactive_member', user.membership_state
    assert_equal stamp.to_i, user.membership_cancelled_at.to_i
    assert_equal CANCELLED_AT.to_i, user.membership_cancelled_at.to_i
  end

  private

  def with_recharge_enabled
    settings = RechargeConfig.settings
    previous = settings.api_key
    settings.api_key = 'test-key'
    yield
  ensure
    settings.api_key = previous
  end

  def cancel_member
    user = User.create!(
      authentik_id: "dwello-#{SecureRandom.hex(4)}",
      full_name: 'Steve Dwello',
      payment_type: 'recharge',
      membership_state: 'current_member',
      membership_plan: membership_plans(:monthly_standard),
      last_payment_date: PAID_ON.to_date,
      dues_due_at: Time.zone.local(2026, 10, 27, 0, 0, 0),
      recharge_customer_id: "cust-dwello-#{SecureRandom.hex(4)}"
    )
    RechargePayment.create!(
      recharge_id: "ch-dwello-#{user.id}",
      user: user,
      status: 'SUCCESS',
      amount: 40,
      currency: 'USD',
      processed_at: PAID_ON,
      raw_attributes: { 'customer' => { 'id' => user.recharge_customer_id } }
    )
    assert_equal :cancelled, Recharge::SubscriptionCancellation.call(
      user: user, subscription: subscription_for(user), source: 'test'
    )
    user
  end

  def subscription_for(user)
    {
      status: 'CANCELLED',
      recharge_subscription_id: "sub-dwello-#{user.id}",
      customer_id: user.recharge_customer_id,
      email: user.email,
      product_title: 'Monthly',
      price: 40.0,
      cancelled_at: CANCELLED_AT
    }
  end

  def charge_for(user)
    payment = user.recharge_payments.order(:id).last
    {
      status: 'SUCCESS',
      recharge_id: payment.recharge_id,
      amount: payment.amount,
      currency: 'USD',
      processed_at: payment.processed_at,
      charge_type: 'recurring',
      customer_id: user.recharge_customer_id,
      customer_name: user.full_name,
      raw_attributes: { 'customer' => { 'id' => user.recharge_customer_id } }
    }
  end

  class ChargeClient
    def initialize(charge)
      @charge = charge
    end

    def charges(start_time:)
      start_time ? [@charge] : []
    end
  end

  class SubscriptionClient
    def initialize(subscription)
      @subscription = subscription
    end

    def subscriptions(start_time:)
      start_time ? [@subscription] : []
    end
  end
end
