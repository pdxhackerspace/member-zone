require 'test_helper'

module Reminders
  class PaymentOverdueEligibilityOptOutTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      ReminderSetting.seed_defaults!
      MembershipSetting.instance.update!(payment_overdue_reminder_repeat_days: 7)
    end

    test 'due excludes members who opted out of payment overdue email' do
      user = overdue_user(email: 'opted-out-overdue@example.com')
      NotificationOptOut.opt_out!(user, category: 'payment_overdue', channel: 'email')

      assert_not_includes PaymentOverdueEligibility.due(now: @now), user
    end

    private

    def overdue_user(email:)
      user = User.create!(
        email: email,
        full_name: 'Overdue Member',
        service_account: false,
        membership_state: 'overdue_member',
        payment_type: 'cash',
        dues_due_at: @now - 10.days
      )
      user.update_columns(membership_state_entered_at: @now - 10.days)
      user
    end
  end
end
