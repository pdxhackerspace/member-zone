require 'test_helper'

module Reminders
  class ApplicationReviewEligibilityTest < ActiveSupport::TestCase
    setup do
      ReminderSetting.seed_defaults!
      @setting = ReminderSetting.find_by!(key: 'application_review')
      @now = Time.zone.local(2026, 5, 1, 9, 0, 0)
    end

    test 'due includes submitted applications older than one week' do
      application = stale_application(now: @now, email: 'stale-submitted@example.com', status: 'submitted')

      travel_to @now do
        assert_includes ApplicationReviewEligibility.due.pluck(:id), application.id
      end
    end

    test 'due excludes under review applications when remind_under_review is off' do
      application = stale_application(now: @now, email: 'stale-under-review@example.com', status: 'under_review')
      @setting.update!(remind_under_review: false)

      travel_to @now do
        assert_not_includes ApplicationReviewEligibility.due.pluck(:id), application.id
      end
    end

    test 'due includes under review applications when remind_under_review is on' do
      application = stale_application(now: @now, email: 'stale-under-review-on@example.com', status: 'under_review')
      @setting.update!(remind_under_review: true)

      travel_to @now do
        assert_includes ApplicationReviewEligibility.due.pluck(:id), application.id
      end
    end

    test 'due excludes needs review applications' do
      application = stale_application(now: @now, email: 'parked-needs-review@example.com', status: 'needs_review')
      @setting.update!(remind_under_review: true)

      travel_to @now do
        assert_not_includes ApplicationReviewEligibility.due.pluck(:id), application.id
      end
    end

    test 'due excludes applications reminded within repeat window' do
      application = stale_application(
        now: @now,
        email: 'recently-reminded@example.com',
        application_reminder_sent_at: @now - 2.days
      )

      travel_to @now do
        assert_not_includes ApplicationReviewEligibility.due.pluck(:id), application.id
      end
    end

    private

    def stale_application(now:, email:, status: 'submitted', application_reminder_sent_at: nil)
      MembershipApplication.create!(
        email: email,
        status: status,
        submitted_at: now - 8.days,
        created_at: now - 8.days,
        application_reminder_sent_at: application_reminder_sent_at
      )
    end
  end
end
