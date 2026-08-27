require 'test_helper'

module Reminders
  class ApplicationLinkEligibilityTest < ActiveSupport::TestCase
    setup do
      MembershipSetting.instance.update!(
        application_link_reminder_delay_days: 3,
        application_link_reminder_max_count: 3,
        use_builtin_membership_application: true
      )
      ReminderSetting.seed_defaults!
      ReminderSetting.find_by!(key: 'application_link').update!(enabled: true)
    end

    test 'due includes active verifications awaiting application past delay' do
      now = Time.zone.local(2026, 8, 6, 7, 15, 0)
      verification = awaiting_verification(now: now, email: 'awaiting@example.com')

      travel_to now do
        assert_includes ApplicationLinkEligibility.due(now: now), verification
      end
    end

    test 'due excludes verifications with submitted applications' do
      now = Time.zone.local(2026, 8, 6, 7, 15, 0)
      verification = awaiting_verification(now: now, email: 'submitted@example.com')
      MembershipApplication.create!(
        email: verification.email,
        status: 'submitted',
        submitted_at: now - 1.day,
        created_at: now - 1.day
      )

      travel_to now do
        assert_not_includes ApplicationLinkEligibility.due(now: now), verification
      end
    end

    test 'due excludes verifications reminded inside delay window' do
      now = Time.zone.local(2026, 8, 6, 7, 15, 0)
      verification = awaiting_verification(
        now: now,
        email: 'recent-reminder@example.com',
        application_link_reminder_sent_at: now - 1.day
      )

      travel_to now do
        assert_not_includes ApplicationLinkEligibility.due(now: now), verification
      end
    end

    test 'due excludes verifications at max reminder count' do
      now = Time.zone.local(2026, 8, 6, 7, 15, 0)
      verification = awaiting_verification(
        now: now,
        email: 'max-count@example.com',
        application_link_reminder_count: 3,
        application_link_reminder_sent_at: now - 4.days
      )

      travel_to now do
        assert_not_includes ApplicationLinkEligibility.due(now: now), verification
      end
    end

    test 'due excludes verifications with pending queued reminder matched by verification id' do
      now = Time.zone.local(2026, 8, 6, 7, 15, 0)
      verification = awaiting_verification(now: now, email: 'pending-queue@example.com')
      QueuedMail.create!(
        to: verification.email,
        subject: 'Complete your application',
        body_html: '<p>Reminder</p>',
        body_text: 'Reminder',
        reason: 'Application link reminder',
        mailer_action: 'application_link_reminder',
        status: 'pending',
        mailer_args: { application_verification_id: verification.id }
      )

      travel_to now do
        assert_not_includes ApplicationLinkEligibility.due(now: now), verification
        assert_not ApplicationLinkEligibility.due?(verification, now: now)
      end
    end

    test 'count_due returns zero when builtin application is disabled' do
      now = Time.zone.local(2026, 8, 6, 7, 15, 0)
      ReminderSetting.seed_defaults!
      ReminderSetting.find_by!(key: 'application_link').update!(enabled: true)
      MembershipSetting.instance.update!(use_builtin_membership_application: false)
      awaiting_verification(now: now, email: 'builtin-off@example.com')

      travel_to now do
        assert_equal 0, ApplicationLinkEligibility.count_due(now: now)
      end
    end

    test 'due and count_due exclude verifications when application matches by email but not digest' do
      now = Time.zone.local(2026, 8, 6, 7, 15, 0)
      verification = awaiting_verification(now: now, email: 'digest-mismatch@example.com')
      application = MembershipApplication.create!(
        email: verification.email,
        status: 'submitted',
        submitted_at: now - 1.day,
        created_at: now - 1.day
      )
      application.update_columns(
        email: verification.email,
        email_lookup_digest: 'legacy-mismatch'
      )

      travel_to now do
        assert_not verification.awaiting_application?
        assert_not ApplicationLinkEligibility.due?(verification, now: now)
        assert_not_includes ApplicationLinkEligibility.due(now: now), verification
        assert_equal 0, ApplicationLinkEligibility.count_due(now: now)
      end
    end

    test 'count_due matches due scope size' do
      now = Time.zone.local(2026, 8, 6, 7, 15, 0)
      awaiting_verification(now: now, email: 'count-match@example.com')

      travel_to now do
        assert_equal ApplicationLinkEligibility.due(now: now).size, ApplicationLinkEligibility.count_due(now: now)
      end
    end

    test 'due excludes verifications for members who opted out of application reminders' do
      now = Time.zone.local(2026, 8, 6, 7, 15, 0)
      user = users(:member_with_local_account)
      verification = awaiting_verification(now: now, email: user.email)
      NotificationOptOut.opt_out!(user, category: 'application_link', channel: 'email')

      travel_to now do
        assert_not_includes ApplicationLinkEligibility.due(now: now), verification
      end
    end

    private

    def awaiting_verification(now:, email:, **attrs)
      ApplicationVerification.create!(
        {
          email: email,
          confirmed_open_house: true,
          confirmed_code_of_conduct: true,
          created_at: now - 4.days,
          expires_at: now + 2.days
        }.merge(attrs)
      )
    end
  end
end
