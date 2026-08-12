require 'test_helper'

class OrientationReminderJobTest < ActiveJob::TestCase
  setup do
    ReminderSetting.find_or_create_by!(key: 'orientation') do |setting|
      setting.name = 'Orientation reminder'
      setting.description = 'Test'
      setting.enabled = false
    end
  end

  test 'perform completes when reminder is disabled' do
    assert_nil OrientationReminderJob.perform_now
  end

  test 'perform sends when reminder is enabled and members are due' do
    now = Time.zone.local(2026, 8, 5, 7, 0, 0)
    ReminderSetting.find_by!(key: 'orientation').update!(enabled: true)
    MembershipSetting.instance.update!(
      orientation_reminder_repeat_days: 14,
      new_member_expiry_days: 90,
      building_access_training_topic: training_topics(:building_access)
    )
    EmailTemplate.where(key: 'orientation_reminder').delete_all
    EmailTemplate.create!(
      key: 'orientation_reminder',
      name: 'Orientation Reminder',
      subject: 'Book your orientation',
      body_html: '<p>Hi</p>',
      body_text: 'Hi',
      enabled: true,
      send_immediately: true
    )
    user = User.create!(
      email: 'job-orientation@example.com',
      full_name: 'Job Orientation Target',
      service_account: false,
      membership_state: 'new_member',
      payment_type: 'unknown'
    )
    user.update_columns(membership_state_entered_at: now - 20.days)
    MembershipApplication.create!(
      user: user,
      email: user.email,
      status: 'approved',
      reviewed_at: now - 20.days,
      submitted_at: now - 22.days
    )

    travel_to now do
      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        OrientationReminderJob.perform_now
      end
    end
  end
end
