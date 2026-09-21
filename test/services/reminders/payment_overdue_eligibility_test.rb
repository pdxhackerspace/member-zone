require 'test_helper'

module Reminders
  class PaymentOverdueEligibilityTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      # base_user? resolves membership state through effective_membership_state, which reads the
      # real clock rather than the injected now. Without freezing it, these members drift out of
      # their overdue grace period as the wall clock moves and stop being due.
      travel_to @now
      MembershipSetting.instance.update!(overdue_grace_period_days: 30)
      set_reminder_cadence('payment_overdue', start_offset_days: 5, interval_days: 7, max_reminders: nil)
    end

    test 'due includes overdue members who have never been reminded' do
      user = overdue_user(email: 'never-reminded@example.com')

      assert_includes PaymentOverdueEligibility.due(now: @now), user
      assert PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due excludes members who cancelled' do
      user = overdue_user(email: 'cancelled@example.com')
      user.record_cancellation!

      assert_not_includes PaymentOverdueEligibility.due(now: @now), user
      assert_not PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due excludes members who have already fallen inactive' do
      user = overdue_user(email: 'already-inactive@example.com')
      user.update_columns(membership_state: 'inactive_member')

      assert_not_includes PaymentOverdueEligibility.due(now: @now), user.reload
      assert_not PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due excludes an overdue member whose grace period has run out' do
      user = overdue_user(email: 'grace-expired@example.com')
      user.update_columns(membership_state_entered_at: @now - 31.days)

      assert_not PaymentOverdueEligibility.due?(user.reload, now: @now)
    end

    test 'due excludes a member on the day their payment was due' do
      user = overdue_user(email: 'due-today@example.com', overdue_for: 0)

      assert PaymentOverdueEligibility.within_grace_period?(user, now: @now)
      assert_not PaymentOverdueEligibility.due?(user, now: @now)
      assert_not_includes PaymentOverdueEligibility.due(now: @now), user
    end

    test 'due excludes a member still inside the reminder grace period' do
      user = overdue_user(email: 'inside-grace@example.com', overdue_for: 4)

      assert_not PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due includes a member the day the reminder grace period ends' do
      user = overdue_user(email: 'grace-just-up@example.com', overdue_for: 5)

      assert_not PaymentOverdueEligibility.within_grace_period?(user, now: @now)
      assert PaymentOverdueEligibility.due?(user, now: @now)
      assert_includes PaymentOverdueEligibility.due(now: @now), user
    end

    test 'the wait before the first reminder follows the start offset' do
      user = overdue_user(email: 'longer-grace@example.com', overdue_for: 6)
      set_reminder_cadence('payment_overdue', start_offset_days: 10)

      assert_not PaymentOverdueEligibility.due?(user, now: @now)

      set_reminder_cadence('payment_overdue', start_offset_days: 0)

      assert PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due stops once the maximum number of reminders has gone out' do
      user = overdue_user(email: 'maxed-out@example.com', overdue_for: 20)
      set_reminder_cadence('payment_overdue', max_reminders: 2)
      record_reminder_sent('payment_overdue', user, at: @now - 10.days, times: 2)

      assert_not PaymentOverdueEligibility.due?(user.reload, now: @now)
      assert_not_includes PaymentOverdueEligibility.due(now: @now), user
    end

    # A member who pays up and falls behind again is at reminder one, not wherever the last
    # spell left off — the anchor moved, so the sequence restarted.
    test 'a fresh overdue spell starts the sequence over' do
      user = overdue_user(email: 'lapsed-again@example.com', overdue_for: 20)
      set_reminder_cadence('payment_overdue', max_reminders: 2)
      record_reminder_sent('payment_overdue', user, at: @now - 10.days, anchor: @now - 400.days, times: 2)

      assert PaymentOverdueEligibility.due?(user.reload, now: @now)
      assert_includes PaymentOverdueEligibility.due(now: @now), user
    end

    # A member whose stored state has not caught up is overdue as of the dues date that
    # passed, not as of whenever Membership::TickJob gets around to moving them.
    test 'grace period for a current member runs from their paid-through date' do
      user = User.create!(
        email: 'current-inside-grace@example.com',
        full_name: 'Barely Past Due',
        service_account: false,
        membership_state: 'current_member',
        payment_type: 'cash',
        dues_due_at: @now - 2.days
      )
      user.update_columns(membership_state: 'current_member', membership_state_entered_at: @now - 60.days)

      assert_equal 'overdue_member', user.reload.effective_membership_state
      assert_not PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'overdue_counts reports members held back by the grace period' do
      overdue_user(email: 'counted-due@example.com', overdue_for: 10)
      overdue_user(email: 'counted-in-grace@example.com', overdue_for: 1)

      counts = PaymentOverdueEligibility.overdue_counts(now: @now)

      assert_equal 2, counts[:total]
      assert_equal 1, counts[:within_grace]
      assert_equal 1, PaymentOverdueEligibility.count_due(now: @now)
    end

    test 'due excludes members reminded inside the repeat window' do
      user = overdue_user(email: 'recently-reminded@example.com')
      record_reminder_sent('payment_overdue', user, at: @now - 3.days)

      assert_not_includes PaymentOverdueEligibility.due(now: @now), user.reload
      assert_not PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due includes members reminded outside the repeat window' do
      user = overdue_user(email: 'reminded-long-ago@example.com')
      record_reminder_sent('payment_overdue', user, at: @now - 8.days)

      assert_includes PaymentOverdueEligibility.due(now: @now), user.reload
      assert PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due excludes members with reminder mail still awaiting review' do
      user = overdue_user(email: 'awaiting-review@example.com')
      queue_reminder_mail(user, status: 'pending')

      assert_not_includes PaymentOverdueEligibility.due(now: @now), user
      assert_not PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due includes members whose reminder mail was rejected' do
      user = overdue_user(email: 'rejected-reminder@example.com')
      queue_reminder_mail(user, status: 'rejected')

      assert_includes PaymentOverdueEligibility.due(now: @now), user
      assert PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due excludes members with no email to write to' do
      user = overdue_user(email: 'no-email@example.com')
      user.update_columns(email: nil, email_lookup_digest: nil)

      assert_not_includes PaymentOverdueEligibility.due(now: @now), user.reload
      assert_not PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due excludes service accounts' do
      user = overdue_user(email: 'service-overdue@example.com')
      user.update_columns(service_account: true)

      assert_not_includes PaymentOverdueEligibility.due(now: @now), user.reload
      assert_not PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due includes a current member whose paid-through date has passed' do
      travel_to @now do
        user = User.create!(
          email: 'past-due-current@example.com',
          full_name: 'Past Due Current',
          service_account: false,
          membership_state: 'current_member',
          payment_type: 'cash',
          dues_due_at: @now - 10.days
        )
        user.update_columns(membership_state: 'current_member', membership_state_entered_at: @now - 60.days)

        assert PaymentOverdueEligibility.due?(user, now: @now)
        assert_includes PaymentOverdueEligibility.due(now: @now), user
      end
    end

    test 'due excludes an overdue member whose cancellation has not been recorded yet' do
      user = overdue_user(email: 'filed-cancellation@example.com')
      file_cancellation(user, at: @now - 5.days)

      assert_not PaymentOverdueEligibility.due?(user, now: @now)
      assert_not_includes PaymentOverdueEligibility.due(now: @now), user
    end

    test 'due still includes an overdue member who paid after an old cancellation' do
      user = overdue_user(email: 'resubscribed-then-lapsed@example.com')
      file_cancellation(user, at: @now - 1.year)
      user.update_columns(last_payment_date: (@now - 60.days).to_date)

      assert PaymentOverdueEligibility.due?(user.reload, now: @now)
    end

    # Membership::CancellationReconciler counts a subscription started or resumed after the
    # notice as a return and leaves the member's standing alone. If this disagreed, such a
    # member would be stuck: nothing would move them, and nothing would ever chase them again.
    test 'due includes an overdue member who resubscribed without the payment columns catching up' do
      user = overdue_user(email: 'restarted-subscription@example.com')
      file_cancellation(user, at: @now - 1.year)
      file_event(user, event_type: 'subscription_resumed', at: @now - 30.days)

      assert PaymentOverdueEligibility.due?(user.reload, now: @now)
      assert_includes PaymentOverdueEligibility.due(now: @now), user
    end

    test 'total_overdue counts every overdue member regardless of reminder history' do
      overdue_user(email: 'overdue-a@example.com')
      reminded = overdue_user(email: 'overdue-b@example.com')
      record_reminder_sent('payment_overdue', reminded, at: @now)

      assert_equal 2, PaymentOverdueEligibility.total_overdue
      assert_equal 1, PaymentOverdueEligibility.count_due(now: @now)
    end

    private

    # Ten days behind clears the five-day reminder grace period without running into the
    # thirty-day overdue grace period at the far end.
    def overdue_user(email:, overdue_for: 10)
      user = User.create!(
        email: email,
        full_name: 'Overdue Member',
        service_account: false,
        membership_state: 'overdue_member',
        payment_type: 'unknown'
      )
      user.update_columns(membership_state_entered_at: @now - overdue_for.days)
      user.reload
    end

    def file_cancellation(user, at:)
      file_event(user, event_type: 'subscription_cancelled', at: at)
    end

    def file_event(user, event_type:, at:)
      PaymentEvent.create!(
        user: user,
        event_type: event_type,
        source: 'recharge',
        occurred_at: at,
        external_id: "recharge-sub-#{SecureRandom.hex(4)}-#{event_type}",
        details: "Recharge #{event_type.humanize.downcase}"
      )
    end

    def queue_reminder_mail(user, status:)
      QueuedMail.create!(
        to: user.email,
        subject: 'Your dues are past due',
        body_html: '<p>Hi</p>',
        body_text: 'Hi',
        reason: 'Dues overdue',
        mailer_action: 'payment_past_due',
        recipient: user,
        status: status,
        reviewed_by: status == 'rejected' ? users(:one) : nil,
        reviewed_at: status == 'rejected' ? @now - 1.day : nil
      )
    end
  end
end
