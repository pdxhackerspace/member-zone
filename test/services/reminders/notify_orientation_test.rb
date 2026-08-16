require 'test_helper'

module Reminders
  class NotifyOrientationTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      @topic = training_topics(:building_access)
      MembershipSetting.instance.update!(
        orientation_reminder_repeat_days: 14,
        new_member_expiry_days: 90,
        building_access_training_topic: @topic
      )
      ReminderSetting.find_or_create_by!(key: 'orientation') do |setting|
        setting.name = 'Orientation reminder'
        setting.description = 'Test'
      end
      ReminderSetting.find_by!(key: 'orientation').update!(enabled: true)
      EmailTemplate.where(key: 'orientation_reminder').delete_all
      EmailTemplate.create!(
        key: 'orientation_reminder',
        name: 'Orientation Reminder',
        subject: '{{organization_name}}: Book your building access orientation',
        body_html: '<p>Hi {{member_name}}, approved {{days_since_approval}} days ago</p>',
        body_text: 'Hi {{member_name}}, approved {{days_since_approval}} days ago',
        enabled: true,
        send_immediately: true
      )
    end

    test 'sends the reminder and stamps when it went out' do
      user = awaiting_user(email: 'notify-orientation@example.com')

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        NotifyOrientation.call(now: @now)
      end

      assert_equal @now, user.reload.orientation_reminder_sent_at
    end

    test 'sends nothing while the reminder is disabled' do
      ReminderSetting.find_by!(key: 'orientation').update!(enabled: false)
      awaiting_user(email: 'orientation-disabled@example.com')

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        NotifyOrientation.call(now: @now)
      end
    end

    test 'does not stamp when the mail is held for review' do
      EmailTemplate.find_by!(key: 'orientation_reminder').update!(send_immediately: false)
      user = awaiting_user(email: 'orientation-held@example.com')

      assert_difference 'QueuedMail.count', 1 do
        assert_no_difference -> { ActionMailer::Base.deliveries.size } do
          NotifyOrientation.call(now: @now)
        end
      end

      assert_nil user.reload.orientation_reminder_sent_at
    end

    test 'leaves members who have had their orientation alone' do
      user = awaiting_user(email: 'orientation-done@example.com')
      Training.create!(trainee: user, training_topic: @topic, trained_at: @now - 1.day)

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        NotifyOrientation.call(now: @now)
      end
    end

    test 'tells the member how long ago they were approved' do
      awaiting_user(email: 'days-waiting@example.com', approved_ago: 21.days)

      NotifyOrientation.call(now: @now)

      assert_match 'approved 21 days ago', ActionMailer::Base.deliveries.last.to_s
    end

    test 'stamps the member when mail held for review is later delivered' do
      EmailTemplate.find_by!(key: 'orientation_reminder').update!(send_immediately: false)
      user = awaiting_user(email: 'orientation-deferred@example.com')
      NotifyOrientation.call(now: @now)

      QueuedMail.find_by!(recipient: user, mailer_action: 'orientation_reminder').deliver_now!

      assert_not_nil user.reload.orientation_reminder_sent_at
    end

    private

    def awaiting_user(email:, approved_ago: 20.days)
      user = User.create!(
        email: email,
        full_name: 'Orientation Notify Target',
        service_account: false,
        membership_state: 'new_member',
        payment_type: 'unknown'
      )
      user.update_columns(membership_state_entered_at: @now - approved_ago)
      MembershipApplication.create!(
        user: user,
        email: email,
        status: 'approved',
        reviewed_at: @now - approved_ago,
        submitted_at: @now - approved_ago - 2.days
      )
      user.reload
    end
  end
end
