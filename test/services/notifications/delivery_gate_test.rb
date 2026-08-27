require 'test_helper'

module Notifications
  class DeliveryGateTest < ActiveSupport::TestCase
    setup do
      @user = users(:member_with_local_account)
      ReminderSetting.seed_defaults!
    end

    test 'does not block mandatory categories' do
      assert_not DeliveryGate.blocked?(mailer_action: 'parking_permit_issued', user: @user)
      assert_not DeliveryGate.blocked?(mailer_action: 'membership_lapsed', user: @user)
    end

    test 'does not block when reminder allows opt-out but member is subscribed' do
      assert_not DeliveryGate.blocked?(mailer_action: 'payment_past_due', user: @user)
    end

    test 'blocks opted-out reminder email for members' do
      NotificationOptOut.opt_out!(@user, category: 'payment_overdue', channel: 'email')

      assert DeliveryGate.blocked?(mailer_action: 'payment_past_due', user: @user)
    end

    test 'does not block parking reminders when opt-out is disabled for category' do
      NotificationOptOut.opt_out!(@user, category: 'parking_notices', channel: 'email')

      assert_not DeliveryGate.blocked?(mailer_action: 'parking_permit_expiring_soon', user: @user)
    end

    test 'blocks application link email for opted-out address' do
      email = 'blocked-applicant@example.com'
      EmailNotificationOptOut.opt_out!(email, category: 'application_link')

      assert DeliveryGate.blocked?(mailer_action: 'application_link_reminder', email: email)
      assert DeliveryGate.blocked?(mailer_action: 'application_email_verification', email: email)
    end

    test 'fails open for unknown mailer actions' do
      assert_not DeliveryGate.blocked?(mailer_action: 'totally_unknown_action', user: @user)
    end

    test 'footer for opt-outable category includes manage link' do
      footer = DeliveryGate.footer_for(mailer_action: 'payment_past_due', user: @user)
      assert footer.opt_out_allowed?
      assert_includes footer.html, 'notification settings'
      assert_includes footer.text, 'http'
    end

    test 'footer for member uses signed token url' do
      footer = DeliveryGate.footer_for(mailer_action: 'payment_past_due', user: @user)

      assert_match %r{/notifications/[^?\s]+}, footer.text
      assert_not_includes footer.text, '/profile/notifications'

      token = footer.text[%r{/notifications/([^?\s]+)}, 1]
      assert_equal @user, User.find_by_token_for(:notification_preferences, token)
    end

    test 'footer for mandatory category explains requirement' do
      footer = DeliveryGate.footer_for(mailer_action: 'parking_permit_issued', user: @user)
      assert footer.mandatory?
      assert_includes footer.html, 'required notice'
    end
  end
end
