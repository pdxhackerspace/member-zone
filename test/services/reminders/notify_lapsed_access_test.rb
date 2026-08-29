require 'test_helper'

module Reminders
  class NotifyLapsedAccessTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      ActionMailer::Base.deliveries.clear
      clear_enqueued_jobs
      ReminderSetting.seed_defaults!
      @setting = ReminderSetting.find_by!(key: 'lapsed_access')
      @setting.update!(enabled: true)
      @now = Time.zone.local(2026, 8, 6, 8, 5, 0)
      MembershipSetting.instance.update!(reactivation_grace_period_months: 12)
      EmailTemplate.where(key: 'lapsed_access_reminder').delete_all
      EmailTemplate.create!(
        key: 'lapsed_access_reminder',
        name: 'Lapsed Member Access Reminder',
        subject: 'Lapsed {{member_name}} on {{lapsed_at}}',
        body_html: '<p>{{reactivation_guidance_html}}</p><p>{{profile_url}}</p>',
        body_text: "{{reactivation_guidance_text}}\n{{profile_url}}",
        enabled: true,
        send_immediately: true
      )
    end

    teardown do
      clear_enqueued_jobs
    end

    test 'does nothing when reminder is disabled' do
      @setting.update!(enabled: false)
      inactive_user(email: 'disabled@example.com')

      travel_to @now do
        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyLapsedAccess.call(now: @now)
          end
        end
      end
    end

    test 'emails inactive members who accessed yesterday' do
      user = inactive_user(email: 'notify-me@example.com')

      travel_to @now do
        assert_difference 'ActionMailer::Base.deliveries.size', 1 do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyLapsedAccess.call(now: @now)
          end
        end
      end

      assert_equal @now, user.reload.lapsed_access_reminder_sent_at
      mail = ActionMailer::Base.deliveries.last
      assert_equal [user.email], mail.to
      assert_includes mail.text_part.body.decoded, 'reactivate without reapplying'
    end

    test 'past reactivation grace period gets contact-the-space guidance' do
      inactive_user(email: 'past-grace@example.com', last_payment: @now - 14.months)

      travel_to @now do
        perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
          NotifyLapsedAccess.call(now: @now)
        end
      end

      mail = ActionMailer::Base.deliveries.last
      assert_includes mail.text_part.body.decoded, 'reactivation window has passed'
    end

    test 'does not email inactive members without yesterday access' do
      inactive_user(email: 'no-yesterday-access@example.com', accessed_at: @now - 2.days)

      travel_to @now do
        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyLapsedAccess.call(now: @now)
          end
        end
      end
    end

    private

    def inactive_user(email:, accessed_at: nil, last_payment: nil)
      accessed_at ||= @now - 1.day
      last_payment ||= (@now - 30.days).to_date
      user = User.create!(
        email: email,
        full_name: 'Inactive Notify User',
        service_account: false,
        membership_state: 'inactive_member',
        payment_type: 'unknown',
        last_payment_date: last_payment
      )
      user.update_columns(membership_state_entered_at: @now - 45.days)
      AccessLog.create!(user: user, logged_at: accessed_at, name: user.display_name, action: 'opened')
      user
    end
  end
end
