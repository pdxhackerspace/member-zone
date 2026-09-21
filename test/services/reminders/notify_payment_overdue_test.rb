require 'test_helper'

module Reminders
  class NotifyPaymentOverdueTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      # See PaymentOverdueEligibilityTest: eligibility partly resolves against the real clock,
      # so these fixed dates only behave if the clock is frozen with them.
      travel_to @now
      MembershipSetting.instance.update!(overdue_grace_period_days: 30)
      set_reminder_cadence('payment_overdue', enabled: true, start_offset_days: 5, interval_days: 7,
                                              max_reminders: nil)
      EmailTemplate.where(key: 'payment_past_due').delete_all
      EmailTemplate.create!(
        key: 'payment_past_due',
        name: 'Payment Past Due',
        subject: '{{organization_name}}: Your dues are past due',
        body_html: '<p>Hi {{member_name}}, {{days_overdue}} days</p>',
        body_text: 'Hi {{member_name}}, {{days_overdue}} days',
        enabled: true,
        send_immediately: true
      )
    end

    test 'sends the reminder and records when it went out' do
      user = overdue_user(email: 'notify-overdue@example.com')

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        NotifyPaymentOverdue.call(now: @now)
      end

      assert_equal @now, ReminderDelivery.state_for('payment_overdue', user).last_sent_at
    end

    test 'sends nothing while the reminder is disabled' do
      ReminderSetting.find_by!(key: 'payment_overdue').update!(enabled: false)
      overdue_user(email: 'reminder-disabled@example.com')

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        NotifyPaymentOverdue.call(now: @now)
      end
    end

    test 'does not record a send when the mail is held for review' do
      EmailTemplate.find_by!(key: 'payment_past_due').update!(send_immediately: false)
      user = overdue_user(email: 'held-for-review@example.com')

      assert_difference 'QueuedMail.count', 1 do
        assert_no_difference -> { ActionMailer::Base.deliveries.size } do
          NotifyPaymentOverdue.call(now: @now)
        end
      end

      assert_nil ReminderDelivery.state_for('payment_overdue', user)
    end

    # Held mail used to leave no trace at all when it finally went out, so the member was due
    # again the next morning and heard the same thing twice.
    test 'records the send when mail held for review is later delivered' do
      EmailTemplate.find_by!(key: 'payment_past_due').update!(send_immediately: false)
      user = overdue_user(email: 'overdue-deferred@example.com')
      NotifyPaymentOverdue.call(now: @now)

      queued = QueuedMail.find_by!(recipient: user, mailer_action: 'payment_past_due')
      queued.update!(status: 'approved')
      queued.deliver_now!

      assert_equal 1, ReminderDelivery.state_for('payment_overdue', user).sent_count
    end

    test 'leaves a member alone until the start offset has passed' do
      user = overdue_user(email: 'still-in-grace@example.com', overdue_for: 2)

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        NotifyPaymentOverdue.call(now: @now)
      end

      assert_nil ReminderDelivery.state_for('payment_overdue', user)
    end

    test 'leaves cancelled members alone' do
      user = overdue_user(email: 'cancelled-not-nagged@example.com')
      user.record_cancellation!

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        NotifyPaymentOverdue.call(now: @now)
      end
    end

    test 'tells the member how many days they are overdue' do
      overdue_user(email: 'days-overdue@example.com', paid_through: @now - 12.days)

      NotifyPaymentOverdue.call(now: @now)

      assert_match '12 days', ActionMailer::Base.deliveries.last.to_s
    end

    private

    # Ten days behind clears the five-day reminder grace period without running into the
    # thirty-day overdue grace period at the far end.
    def overdue_user(email:, paid_through: nil, overdue_for: 10)
      user = User.create!(
        email: email,
        full_name: 'Overdue Notify Target',
        service_account: false,
        membership_state: 'overdue_member',
        payment_type: 'unknown',
        dues_due_at: paid_through
      )
      user.update_columns(membership_state_entered_at: @now - overdue_for.days)
      user.reload
    end
  end
end
