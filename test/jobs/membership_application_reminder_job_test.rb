require 'test_helper'

class MembershipApplicationReminderJobTest < ActiveJob::TestCase
  setup do
    ReminderSetting.seed_defaults!
    ReminderSetting.find_by!(key: 'application_review').update!(enabled: false)
  end

  test 'perform completes when reminder is disabled' do
    assert_nil MembershipApplicationReminderJob.perform_now
  end

  test 'perform sends when reminder is enabled and applications are due' do
    now = Time.zone.local(2026, 5, 1, 9, 0, 0)
    ReminderSetting.find_by!(key: 'application_review').update!(enabled: true)
    EmailTemplate.where(key: 'staff_application_reminder').delete_all
    EmailTemplate.create!(
      key: 'staff_application_reminder',
      name: 'Staff Application Reminder',
      subject: 'Reminder {{member_name}}',
      body_html: '<p>Review</p>',
      body_text: 'Review',
      enabled: true
    )
    grant_privileges(users(:one), 'applications.review')
    MembershipApplication.create!(
      email: 'job-reminder@example.com',
      status: 'submitted',
      submitted_at: now - 8.days,
      created_at: now - 8.days
    )

    travel_to now do
      assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
        MembershipApplicationReminderJob.perform_now
      end
    end
  end
end
