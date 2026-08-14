require 'test_helper'

module Reminders
  class PaymentOverdueEligibilityTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      MembershipSetting.instance.update!(
        payment_overdue_reminder_repeat_days: 7,
        overdue_grace_period_days: 30
      )
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

    test 'due excludes members reminded inside the repeat window' do
      user = overdue_user(email: 'recently-reminded@example.com')
      user.update_columns(payment_overdue_reminder_sent_at: @now - 3.days)

      assert_not_includes PaymentOverdueEligibility.due(now: @now), user.reload
      assert_not PaymentOverdueEligibility.due?(user, now: @now)
    end

    test 'due includes members reminded outside the repeat window' do
      user = overdue_user(email: 'reminded-long-ago@example.com')
      user.update_columns(payment_overdue_reminder_sent_at: @now - 8.days)

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
          dues_due_at: @now - 3.days
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
      reminded.update_columns(payment_overdue_reminder_sent_at: @now)

      assert_equal 2, PaymentOverdueEligibility.total_overdue
      assert_equal 1, PaymentOverdueEligibility.count_due(now: @now)
    end

    private

    def overdue_user(email:)
      user = User.create!(
        email: email,
        full_name: 'Overdue Member',
        service_account: false,
        membership_state: 'overdue_member',
        payment_type: 'unknown'
      )
      user.update_columns(membership_state_entered_at: @now - 2.days)
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
