require 'test_helper'

class MembershipOscillationRepairTest < ActiveSupport::TestCase
  CANCELLED_AT = Time.zone.local(2026, 10, 26, 18, 0, 0)

  test 'preview reports a revived cancellation without changing it' do
    user = nil
    travel_to Time.zone.local(2026, 10, 28, 12, 0, 0) do
      user = revived_cancellation
      capture_io { MembershipOscillationRepair.new(dry_run: true).run }
    end

    assert_equal 'current_member', user.reload.membership_state
    assert_nil user.membership_cancelled_at
  end

  test 'repair puts a revived cancellation back where the paid-through date says' do
    user = nil
    older = nil
    newer = nil
    travel_to Time.zone.local(2026, 10, 28, 12, 0, 0) do
      user = revived_cancellation
      older = queued_mail(user, 'membership_cancelled')
      older.update_columns(created_at: 2.hours.ago)
      newer = queued_mail(user, 'membership_cancelled')
      capture_io { MembershipOscillationRepair.new(dry_run: false).run }
    end

    user.reload
    assert_equal 'inactive_member', user.membership_state
    assert_equal CANCELLED_AT.to_i, user.membership_cancelled_at.to_i
    assert_equal 'pending', older.reload.status
    assert_equal 'rejected', newer.reload.status
  end

  test 'repair sponsors a member a payment sync pulled into paying' do
    user = User.create!(
      authentik_id: "repair-sponsored-#{SecureRandom.hex(4)}",
      full_name: 'Repair Sponsored',
      payment_type: 'paypal',
      membership_state: 'current_member'
    )
    Journal.create!(
      user: user,
      action: 'updated',
      changed_at: 1.day.ago,
      changes_json: { 'membership_state' => { 'from' => 'sponsored_member', 'to' => 'current_member' } }
    )

    capture_io { MembershipOscillationRepair.new(dry_run: false).run }

    user.reload
    assert_equal 'sponsored_member', user.membership_state
    assert user.is_sponsored?
  end

  private

  def revived_cancellation
    user = User.create!(
      authentik_id: "repair-cancel-#{SecureRandom.hex(4)}",
      full_name: 'Repair Cancel',
      payment_type: 'recharge',
      membership_state: 'current_member',
      membership_plan: membership_plans(:monthly_standard),
      last_payment_date: Date.new(2026, 9, 27),
      dues_due_at: Time.zone.local(2026, 10, 27, 0, 0, 0)
    )
    PaymentEvent.create!(
      user: user,
      event_type: 'subscription_cancelled',
      source: 'recharge',
      occurred_at: CANCELLED_AT,
      external_id: "recharge-sub-repair-#{user.id}-subscription_cancelled",
      amount: 40,
      currency: 'USD'
    )
    Journal.create!(
      user: user,
      action: 'updated',
      changed_at: Time.zone.local(2026, 10, 27, 6, 0, 0),
      changes_json: { 'membership_state' => { 'from' => 'inactive_member', 'to' => 'current_member' } }
    )
    user
  end

  def queued_mail(user, action)
    QueuedMail.create!(
      recipient: user,
      to: "repair-#{SecureRandom.hex(4)}@example.com",
      subject: 'Membership',
      body_html: '<p>Hello</p>',
      reason: 'test',
      mailer_action: action,
      status: 'pending'
    )
  end
end
