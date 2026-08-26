require 'test_helper'

class QueuedMailNotificationOptOutTest < ActiveSupport::TestCase
  setup do
    @user = users(:member_with_local_account)
    ReminderSetting.seed_defaults!
    EmailTemplate.where(key: 'payment_past_due').delete_all
  end

  test 'enqueue returns nil when member opted out' do
    NotificationOptOut.opt_out!(@user, category: 'payment_overdue', channel: 'email')

    assert_no_difference 'QueuedMail.count' do
      result = QueuedMail.enqueue(:payment_past_due, @user, reason: 'Test')
      assert_nil result
    end
  end

  test 'enqueue creates mail when member is subscribed' do
    assert_difference 'QueuedMail.count', 1 do
      result = QueuedMail.enqueue(:payment_past_due, @user, reason: 'Test')
      assert result
    end
  end
end
