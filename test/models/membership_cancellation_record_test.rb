require 'test_helper'

# A cancellation is remembered past the state it creates. Once the paid-through date passes
# a cancelled member becomes inactive_member like anyone else who stopped paying, and only
# membership_cancelled_at can tell the two apart — which is what decides whether they get a
# "your membership lapsed" email for a decision they made on purpose.
class MembershipCancellationRecordTest < ActiveSupport::TestCase
  setup do
    MembershipSetting.instance.update!(overdue_grace_period_days: 30)
    EmailTemplate.where(key: %w[membership_cancelled membership_lapsed]).update_all(enabled: true)
  end

  test 'recording a cancellation stamps the date' do
    user = member(state: 'current_member')

    assert user.record_cancellation!
    assert_predicate user.reload, :cancellation_on_file?
    assert_in_delta Time.current.to_i, user.membership_cancelled_at.to_i, 5
  end

  test 'a cancellation can be recorded as of the day it happened' do
    cancelled_at = 4.months.ago
    user = member(state: 'current_member')

    user.record_cancellation!(cancelled_at: cancelled_at)

    assert_equal cancelled_at.to_i, user.reload.membership_cancelled_at.to_i
  end

  test 'a member who lapses after cancelling is not told their membership lapsed' do
    user = member(state: 'cancelled_member', email: 'cancelled-then-lapsed@example.com')
    user.update!(membership_cancelled_at: 2.months.ago)

    assert_no_difference -> { lapsed_mail_count(user) } do
      user.transition_to!('inactive_member')
    end

    assert_equal 'inactive_member', user.reload.membership_state
  end

  # The tick job walks members through overdue_member to inactive_member without passing
  # cancelled_member, so a notice nobody has processed yet has to be enough on its own.
  test 'a filed cancellation nobody has processed still suppresses the lapse email' do
    user = member(state: 'overdue_member', email: 'filed-not-stamped@example.com')
    file_cancellation(user, at: 2.months.ago)

    assert_not_predicate user, :cancellation_recorded?
    assert_predicate user, :cancellation_on_file?

    assert_no_difference -> { lapsed_mail_count(user) } do
      user.transition_to!('inactive_member')
    end
  end

  test 'a filed cancellation the member has since paid past does not suppress the lapse email' do
    user = member(state: 'overdue_member', email: 'filed-then-paid@example.com')
    file_cancellation(user, at: 1.year.ago)
    user.update_columns(last_payment_date: 2.months.ago.to_date)

    assert_not_predicate user.reload, :cancellation_on_file?

    assert_difference -> { lapsed_mail_count(user) }, 1 do
      user.transition_to!('inactive_member')
    end
  end

  test 'a member who simply stops paying is still told their membership lapsed' do
    user = member(state: 'overdue_member', email: 'quietly-lapsed@example.com')

    assert_difference -> { lapsed_mail_count(user) }, 1 do
      user.transition_to!('inactive_member')
    end
  end

  test 'the cancellation is forgotten when a payment brings them back' do
    user = member(state: 'cancelled_member', email: 'came-back@example.com')
    user.update!(membership_cancelled_at: 1.month.ago)

    assert user.record_payment!
    assert_not_predicate user.reload, :cancellation_on_file?
  end

  test 'a member who came back and later lapses hears about that lapse' do
    user = member(state: 'cancelled_member', email: 'back-then-lapsed@example.com')
    user.update!(membership_cancelled_at: 1.month.ago)
    user.record_payment!

    assert_difference -> { lapsed_mail_count(user) }, 1 do
      user.reload.transition_to!('inactive_member')
    end
  end

  # Suppressing mail during a historical replay must not also suppress the bookkeeping,
  # or a returning member would keep a stale cancellation on file forever.
  test 'returning to current clears the cancellation even while mail is suppressed' do
    user = member(state: 'cancelled_member', email: 'quiet-return@example.com')
    user.update!(membership_cancelled_at: 1.month.ago)

    Current.skip_membership_state_email = true
    user.record_payment!
    Current.skip_membership_state_email = nil

    assert_not_predicate user.reload, :cancellation_on_file?
  end

  # Reapplying is the other way back, and it arrives before any money does. Left on file, the
  # stamp from a membership that already ended goes on suppressing the mail for the new one.
  test 'the cancellation is forgotten when someone who left is approved again' do
    user = member(state: 'cancelled_member', email: 'rejoined@example.com')
    user.update!(membership_cancelled_at: 2.months.ago)
    user.transition_to!('inactive_member')

    assert user.reload.approve_application!

    assert_equal 'new_member', user.membership_state
    assert_not_predicate user.reload, :cancellation_on_file?
  end

  test 'a member who rejoined and drifts off again hears that their membership lapsed' do
    user = member(state: 'cancelled_member', email: 'rejoined-then-lapsed@example.com')
    user.update!(membership_cancelled_at: 2.months.ago)
    user.transition_to!('inactive_member')
    user.reload.approve_application!

    assert_difference -> { lapsed_mail_count(user) }, 1 do
      user.reload.transition_to!('inactive_member')
    end
  end

  # Not a rejoin: a sponsorship can end and leave them exactly where the cancellation did, and
  # the membership card reads the stamp to decide what to show while it lasts.
  test 'a sponsorship granted after a cancellation keeps it on file' do
    user = member(state: 'cancelled_member', email: 'sponsored-after-cancelling@example.com')
    user.update!(membership_cancelled_at: 1.month.ago)

    assert user.mark_sponsored!
    assert_predicate user.reload, :cancellation_recorded?
  end

  test 'noting a cancellation records the date without moving the member' do
    user = member(state: 'inactive_member')

    assert user.note_cancellation!(cancelled_at: 6.months.ago)
    assert_equal 'inactive_member', user.reload.membership_state
    assert_predicate user, :cancellation_on_file?
  end

  test 'noting a cancellation does not overwrite one already on file' do
    original = 8.months.ago
    user = member(state: 'inactive_member')
    user.note_cancellation!(cancelled_at: original)

    assert_not user.note_cancellation!(cancelled_at: 1.day.ago)
    assert_equal original.to_i, user.reload.membership_cancelled_at.to_i
  end

  private

  def lapsed_mail_count(user)
    QueuedMail.where(recipient: user, mailer_action: 'membership_lapsed').count
  end

  def file_cancellation(user, at:)
    PaymentEvent.create!(
      user: user,
      event_type: 'subscription_cancelled',
      source: 'recharge',
      occurred_at: at,
      external_id: "recharge-sub-#{SecureRandom.hex(4)}-subscription_cancelled",
      details: 'Recharge subscription cancelled'
    )
    user.reload
  end

  def member(state:, email: nil, **attrs)
    User.create!(
      {
        authentik_id: "cancel-record-#{SecureRandom.hex(4)}",
        full_name: 'Cancellation Record Member',
        email: email || "cancel-record-#{SecureRandom.hex(4)}@example.com",
        payment_type: 'recharge',
        membership_state: state,
        dues_due_at: 2.months.from_now
      }.merge(attrs)
    ).reload
  end
end
