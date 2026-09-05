require 'test_helper'

module Reminders
  class NotifyPaymentOverdueTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      # See PaymentOverdueEligibilityTest: eligibility partly resolves against the real clock,
      # so these fixed dates only behave if the clock is frozen with them.
      travel_to @now
      MembershipSetting.instance.update!(
        payment_overdue_reminder_repeat_days: 7,
        overdue_grace_period_days: 30
      )
      ReminderSetting.find_or_create_by!(key: 'payment_overdue') do |setting|
        setting.name = 'Payment overdue reminder'
        setting.description = 'Test'
      end
      ReminderSetting.find_by!(key: 'payment_overdue').update!(enabled: true)
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

    test 'sends the reminder and stamps when it went out' do
      user = overdue_user(email: 'notify-overdue@example.com')

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        NotifyPaymentOverdue.call(now: @now)
      end

      assert_equal @now, user.reload.payment_overdue_reminder_sent_at
    end

    test 'sends nothing while the reminder is disabled' do
      ReminderSetting.find_by!(key: 'payment_overdue').update!(enabled: false)
      overdue_user(email: 'reminder-disabled@example.com')

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        NotifyPaymentOverdue.call(now: @now)
      end
    end

    test 'does not stamp when the mail is held for review' do
      EmailTemplate.find_by!(key: 'payment_past_due').update!(send_immediately: false)
      user = overdue_user(email: 'held-for-review@example.com')

      assert_difference 'QueuedMail.count', 1 do
        assert_no_difference -> { ActionMailer::Base.deliveries.size } do
          NotifyPaymentOverdue.call(now: @now)
        end
      end

      assert_nil user.reload.payment_overdue_reminder_sent_at
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

    def overdue_user(email:, paid_through: nil)
      user = User.create!(
        email: email,
        full_name: 'Overdue Notify Target',
        service_account: false,
        membership_state: 'overdue_member',
        payment_type: 'unknown',
        dues_due_at: paid_through
      )
      user.update_columns(membership_state_entered_at: @now - 2.days)
      user.reload
    end
  end
end
