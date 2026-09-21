require 'test_helper'

module Reminders
  class NotifySlackSignupTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      set_reminder_cadence('slack_signup', enabled: true, start_offset_days: 7, interval_days: 14,
                                           max_reminders: nil)
      member_sources(:slack).update!(enabled: true)
      EmailTemplate.where(key: 'slack_signup_reminder').delete_all
      EmailTemplate.create!(
        key: 'slack_signup_reminder',
        name: 'Slack Signup Reminder',
        subject: '{{organization_name}}: Join us on Slack',
        body_html: '<p>Hi {{member_name}}</p>',
        body_text: 'Hi {{member_name}}',
        enabled: true,
        send_immediately: true
      )
    end

    test 'sends reminder and records it against the sequence when enabled' do
      user = due_user(email: 'notify-slack@example.com')

      travel_to @now do
        assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
          NotifySlackSignup.call(now: @now)
        end
      end

      delivery = ReminderDelivery.state_for('slack_signup', user)

      assert_equal @now, delivery.last_sent_at
      assert_equal 1, delivery.sent_count
    end

    test 'skips when reminder is disabled' do
      ReminderSetting.find_by!(key: 'slack_signup').update!(enabled: false)
      due_user(email: 'disabled-reminder@example.com')

      travel_to @now do
        assert_no_difference -> { ActionMailer::Base.deliveries.size } do
          NotifySlackSignup.call(now: @now)
        end
      end
    end

    test 'does not record a send when mail is queued for review' do
      EmailTemplate.find_by!(key: 'slack_signup_reminder').update!(send_immediately: false)
      user = due_user(email: 'queued-reminder@example.com')

      travel_to @now do
        assert_difference 'QueuedMail.count', 1 do
          assert_no_difference -> { ActionMailer::Base.deliveries.size } do
            NotifySlackSignup.call(now: @now)
          end
        end
      end

      assert_nil ReminderDelivery.state_for('slack_signup', user)
    end

    test 'deliver_now records legacy slack signup nag mail' do
      EmailTemplate.find_by!(key: 'slack_signup_reminder').update!(send_immediately: false)
      user = due_user(email: 'legacy-nag-mail@example.com')

      travel_to @now do
        NotifySlackSignup.call(now: @now)
      end

      queued_mail = QueuedMail.order(:created_at).last
      queued_mail.update!(mailer_action: 'slack_signup_nag')
      delivery_time = @now + 2.hours

      travel_to delivery_time do
        queued_mail.update!(status: 'approved', reviewed_by: users(:one), reviewed_at: delivery_time)
        queued_mail.deliver_now!
      end

      assert_equal delivery_time, ReminderDelivery.state_for('slack_signup', user).last_sent_at
    end

    private

    def due_user(email:)
      user = User.create!(
        email: email,
        full_name: 'Slack Notify Target',
        active: true,
        service_account: false,
        membership_state: 'current_member',
        payment_type: 'unknown'
      )
      MembershipApplication.create!(
        user: user,
        email: email,
        status: 'approved',
        reviewed_at: @now - 10.days,
        submitted_at: @now - 12.days
      )
      user
    end
  end
end
