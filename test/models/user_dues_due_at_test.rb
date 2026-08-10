require 'test_helper'

class UserDuesDueAtTest < ActiveSupport::TestCase
  test 'dues_due_at_from_payment_cycle monthly' do
    anchor = Date.new(2025, 1, 15)
    plan = membership_plans(:monthly_standard)
    at = User.dues_due_at_from_payment_cycle(anchor, plan)
    assert_equal Time.zone.local(2025, 2, 15, 0, 0, 0), at
  end

  test 'dues_due_at_from_payment_cycle yearly' do
    anchor = Date.new(2025, 1, 15)
    plan = membership_plans(:yearly_standard)
    at = User.dues_due_at_from_payment_cycle(anchor, plan)
    assert_equal Time.zone.local(2026, 1, 15, 0, 0, 0), at
  end

  test 'dues_due_at_from_payment_cycle custom days' do
    anchor = Date.new(2025, 1, 15)
    plan = membership_plans(:personal_equipment_donation)
    at = User.dues_due_at_from_payment_cycle(anchor, plan)
    assert_equal Time.zone.local(2025, 2, 14, 0, 0, 0), at
  end

  test 'dues_due_at_from_payment_cycle one-time returns nil' do
    plan = MembershipPlan.create!(
      name: "One-shot #{SecureRandom.hex(4)}",
      cost: 10,
      billing_frequency: 'one-time',
      plan_type: 'primary',
      visible: false,
      manual: true
    )
    assert_nil User.dues_due_at_from_payment_cycle(Date.current, plan)
  end

  test 'apply_payment_updates sets dues_due_at for paying member' do
    user = users(:cash_payer)
    user.update_columns(dues_due_at: nil, last_payment_date: nil)
    paid_on = Date.new(2025, 6, 1)
    updates = user.apply_payment_updates({ time: paid_on.midday, amount: 100.0 }, { payment_type: 'cash' })
    assert updates[:dues_due_at].present?
    assert_equal Date.new(2025, 7, 1), updates[:dues_due_at].to_date
  end

  test 'apply_payment_updates does not set dues_due_at for sponsored member' do
    user = users(:cash_payer)
    user.update_columns(membership_state: 'sponsored_member', membership_status: 'sponsored',
                        payment_type: 'sponsored', dues_due_at: 2.months.from_now)
    future_end = user.dues_due_at
    paid_on = Date.new(2025, 6, 1)
    updates = user.apply_payment_updates({ time: paid_on.midday, amount: 100.0 }, {})
    assert_nil updates[:dues_due_at]
    user.reload
    assert_equal future_end.to_i, user.dues_due_at.to_i
  end

  test 'next_payment_date reads from dues_due_at' do
    user = users(:cash_payer)
    d = Time.zone.local(2026, 3, 10, 0, 0, 0)
    user.update!(dues_due_at: d)
    assert_equal Date.new(2026, 3, 10), user.next_payment_date
  end

  test 'sponsored_guest_duration_months sets dues_due_at before save' do
    user = User.new(
      authentik_id: "test-#{SecureRandom.hex(4)}",
      full_name: 'Limited Guest',
      username: "limitedguest#{SecureRandom.hex(2)}",
      email: "limited#{SecureRandom.hex(4)}@example.com",
      membership_state: 'guest_member',
      payment_type: 'inactive',
      profile_visibility: 'members',
      sponsored_guest_duration_months: 6
    )
    user.save!
    assert user.dues_due_at.present?
    assert user.dues_due_at > 5.months.from_now
    assert user.dues_due_at < 7.months.from_now
  end

  test 'on_paypal_payment_linked sets dues_due_at from plan cycle' do
    user = users(:one)
    plan = membership_plans(:monthly_standard)
    user.update!(membership_plan: plan, membership_state: 'current_member', payment_type: 'paypal')
    user.on_paypal_payment_linked(paypal_payments(:sample_payment))
    user.reload
    assert_equal Date.new(2025, 12, 14), user.dues_due_at.to_date
  end

  test 'on_recharge_payment_linked sets dues_due_at from plan cycle' do
    user = users(:one)
    plan = membership_plans(:monthly_standard)
    user.update!(membership_plan: plan, membership_state: 'current_member', payment_type: 'recharge')
    user.on_recharge_payment_linked(recharge_payments(:recharge_payment))
    user.reload
    assert_equal Date.new(2025, 12, 13), user.dues_due_at.to_date
  end

  test 'sponsored_guest_duration_months zero clears dues_due_at for guest' do
    user = User.create!(
      authentik_id: "test-#{SecureRandom.hex(4)}",
      full_name: 'Guest Clear',
      username: "guestclear#{SecureRandom.hex(2)}",
      email: "guestclear#{SecureRandom.hex(4)}@example.com",
      membership_state: 'guest_member',
      payment_type: 'inactive',
      profile_visibility: 'members',
      dues_due_at: 1.month.from_now
    )
    user.sponsored_guest_duration_months = 0
    user.save!
    assert_nil user.reload.dues_due_at
  end
end
