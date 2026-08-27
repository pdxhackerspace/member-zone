require 'test_helper'

class QueuedMailNotificationOptOutTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

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

  test 'deliver_now! blocks when member opted out after queueing' do
    mail = QueuedMail.enqueue(:payment_past_due, @user, reason: 'Test')
    mail.update!(status: 'approved', reviewed_by: users(:one), reviewed_at: Time.current)

    NotificationOptOut.opt_out!(@user, category: 'payment_overdue', channel: 'email')

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      mail.deliver_now!
    end

    assert_predicate mail.reload, :rejected?
    assert_nil mail.sent_at
    assert_match 'opted out', mail.mail_log_entries.where(event: 'rejected').last.details
  end

  test 'approve! refuses delivery when member opted out after queueing' do
    mail = QueuedMail.create!(
      to: @user.email,
      subject: 'Reminder',
      body_html: '<p>Hi</p>',
      body_text: 'Hi',
      reason: 'Test',
      mailer_action: 'payment_past_due',
      recipient: @user,
      status: 'pending'
    )

    NotificationOptOut.opt_out!(@user, category: 'payment_overdue', channel: 'email')

    assert_no_enqueued_jobs only: QueuedMailDeliveryJob do
      assert_not mail.approve!(users(:one))
    end

    assert_predicate mail.reload, :rejected?
  end
end
