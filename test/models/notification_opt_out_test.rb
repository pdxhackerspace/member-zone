require 'test_helper'

class NotificationOptOutTest < ActiveSupport::TestCase
  setup do
    @user = users(:member_with_local_account)
    ReminderSetting.seed_defaults!
  end

  test 'opt_out and opt_in round trip' do
    assert_not NotificationOptOut.opted_out?(@user, category: 'payment_overdue')

    NotificationOptOut.opt_out!(@user, category: 'payment_overdue', channel: 'email')
    assert NotificationOptOut.opted_out?(@user, category: 'payment_overdue', channel: 'email')
    assert_not NotificationOptOut.opted_out?(@user, category: 'payment_overdue', channel: 'slack')

    NotificationOptOut.opt_in!(@user, category: 'payment_overdue', channel: 'email')
    assert_not NotificationOptOut.opted_out?(@user, category: 'payment_overdue')
  end

  test 'count_for_reminder counts distinct users for reminder category' do
    NotificationOptOut.opt_out!(@user, category: 'slack_signup', channel: 'email')
    NotificationOptOut.opt_out!(@user, category: 'slack_signup', channel: 'slack')

    assert_equal 1, NotificationOptOut.count_for_reminder('slack_signup')
  end
end
