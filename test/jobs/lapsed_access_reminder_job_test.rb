require 'test_helper'

class LapsedAccessReminderJobTest < ActiveJob::TestCase
  setup do
    ReminderSetting.seed_defaults!
    ReminderSetting.find_by!(key: 'lapsed_access').update!(enabled: false)
  end

  test 'perform completes when reminder is disabled' do
    assert_nil LapsedAccessReminderJob.perform_now
  end

  test 'perform sends when reminder is enabled and members are due' do
    now = Time.zone.local(2026, 8, 6, 8, 5, 0)
    ReminderSetting.find_by!(key: 'lapsed_access').update!(enabled: true)
    EmailTemplate.where(key: 'lapsed_access_reminder').delete_all
    EmailTemplate.create!(
      key: 'lapsed_access_reminder',
      name: 'Lapsed Member Access Reminder',
      subject: 'Lapsed',
      body_html: '<p>Hi</p>',
      body_text: 'Hi',
      enabled: true,
      send_immediately: true
    )
    user = User.create!(
      email: 'job-reminder@example.com',
      full_name: 'Job Reminder User',
      service_account: false,
      membership_state: 'inactive_member',
      payment_type: 'unknown',
      last_payment_date: (now - 30.days).to_date
    )
    user.update_columns(membership_state_entered_at: now - 45.days)
    AccessLog.create!(user: user, logged_at: now - 1.day, name: user.display_name, action: 'opened')

    travel_to now do
      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        LapsedAccessReminderJob.perform_now
      end
    end
  end
end
