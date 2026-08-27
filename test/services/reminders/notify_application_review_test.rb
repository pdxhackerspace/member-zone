require 'test_helper'

module Reminders
  class NotifyApplicationReviewTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      ActionMailer::Base.deliveries.clear
      clear_enqueued_jobs
      ReminderSetting.seed_defaults!
      @setting = ReminderSetting.find_by!(key: 'application_review')
      @setting.update!(enabled: true)
      EmailTemplate.where(key: 'staff_application_reminder').delete_all
      EmailTemplate.create!(
        key: 'staff_application_reminder',
        name: 'Staff Application Reminder',
        subject: 'Reminder {{member_name}} after {{application_age_days}} days',
        body_html: '<p>{{application_url}}</p><p>{{submitted_at}}</p>',
        body_text: "Open: {{application_url}}\nSubmitted: {{submitted_at}}",
        enabled: true
      )
    end

    teardown do
      clear_enqueued_jobs
    end

    test 'does nothing when reminder is disabled' do
      @setting.update!(enabled: false)
      now = Time.zone.local(2026, 5, 1, 9, 0, 0)
      stale_application(now: now, email: 'disabled-reminder@example.com')
      train_staff(users(:one))

      travel_to now do
        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyApplicationReview.call(now: now)
          end
        end
      end
    end

    test 'emails executive application reviewers for applications pending after a week' do
      now = Time.zone.local(2026, 5, 1, 9, 0, 0)
      application = stale_application(now: now, email: 'stale-review@example.com')
      train_staff(users(:one))
      train_staff(users(:two))

      travel_to now do
        assert_difference 'ActionMailer::Base.deliveries.size', 2 do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyApplicationReview.call(now: now)
          end
        end
      end

      assert_equal now, application.reload.application_reminder_sent_at
      assert_equal [users(:one).email, users(:two).email].sort,
                   ActionMailer::Base.deliveries.flat_map(&:to).sort

      mail = ActionMailer::Base.deliveries.first
      assert_equal 'Reminder Applicant after 8 days', mail.subject
      assert_includes mail.text_part.body.decoded, "/membership_applications/#{application.id}"
      assert_includes mail.text_part.body.decoded, 'April 23, 2026'
    end

    test 'queues reminder emails through Action Mailer before delivery' do
      now = Time.zone.local(2026, 5, 1, 9, 0, 0)
      stale_application(now: now, email: 'queued-reminder@example.com')
      train_staff(users(:one))

      travel_to now do
        assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
          NotifyApplicationReview.call(now: now)
        end
      end
    ensure
      clear_enqueued_jobs
    end

    test 'does not email applications that are not stale and pending' do
      now = Time.zone.local(2026, 5, 1, 9, 0, 0)
      train_staff(users(:one))
      stale_application(now: now, email: 'already-approved@example.com', status: 'approved')
      stale_application(now: now, email: 'already-rejected@example.com', status: 'rejected')
      stale_application(now: now, email: 'recently-reminded@example.com', application_reminder_sent_at: now - 2.days)
      MembershipApplication.create!(
        email: 'too-new@example.com',
        status: 'submitted',
        submitted_at: now - 6.days,
        created_at: now - 6.days
      )

      travel_to now do
        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyApplicationReview.call(now: now)
          end
        end
      end
    end

    test 'does not email under review applications when remind_under_review is off' do
      now = Time.zone.local(2026, 5, 1, 9, 0, 0)
      @setting.update!(remind_under_review: false)
      train_staff(users(:one))
      application = stale_application(now: now, email: 'under-review-off@example.com', status: 'under_review')

      travel_to now do
        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyApplicationReview.call(now: now)
          end
        end
      end

      assert_nil application.reload.application_reminder_sent_at
    end

    test 'emails under review applications when remind_under_review is on' do
      now = Time.zone.local(2026, 5, 1, 9, 0, 0)
      @setting.update!(remind_under_review: true)
      train_staff(users(:one))
      application = stale_application(now: now, email: 'under-review-on@example.com', status: 'under_review')

      travel_to now do
        assert_difference 'ActionMailer::Base.deliveries.size', 1 do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyApplicationReview.call(now: now)
          end
        end
      end

      assert_equal now, application.reload.application_reminder_sent_at
    end

    test 'emails applications again when the previous reminder is at least three days old' do
      now = Time.zone.local(2026, 5, 1, 9, 0, 0)
      application = stale_application(
        now: now,
        email: 'repeat-due@example.com',
        application_reminder_sent_at: now - 3.days
      )
      train_staff(users(:one))

      travel_to now do
        assert_difference 'ActionMailer::Base.deliveries.size', 1 do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyApplicationReview.call(now: now)
          end
        end
      end

      assert_equal now, application.reload.application_reminder_sent_at
    end

    test 'does not repeat reminder before three days have passed' do
      now = Time.zone.local(2026, 5, 1, 9, 0, 0)
      application = stale_application(
        now: now,
        email: 'repeat-not-due@example.com',
        application_reminder_sent_at: now - 2.days
      )
      train_staff(users(:one))

      travel_to now do
        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyApplicationReview.call(now: now)
          end
        end
      end

      assert_equal now - 2.days, application.reload.application_reminder_sent_at
    end

    test 'deduplicates reviewers and only marks sent when a recipient exists' do
      now = Time.zone.local(2026, 5, 1, 9, 0, 0)
      application = stale_application(now: now, email: 'dedupe@example.com')
      train_staff(users(:one))
      train_staff(users(:one))
      staff_without_email = users(:no_email)
      train_staff(staff_without_email)

      travel_to now do
        assert_difference 'ActionMailer::Base.deliveries.size', 1 do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyApplicationReview.call(now: now)
          end
        end
      end

      assert_equal now, application.reload.application_reminder_sent_at
      assert_equal [users(:one).email], ActionMailer::Base.deliveries.flat_map(&:to)
    end

    test 'leaves stale application unmarked when no director recipients exist' do
      now = Time.zone.local(2026, 5, 1, 9, 0, 0)
      application = stale_application(now: now, email: 'no-recipients@example.com')

      travel_to now do
        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyApplicationReview.call(now: now)
          end
        end
      end

      assert_nil application.reload.application_reminder_sent_at
    end

    test 'does not email applications parked as needs review' do
      now = Time.zone.local(2026, 5, 1, 9, 0, 0)
      @setting.update!(remind_under_review: true)
      train_staff(users(:one))
      application = stale_application(
        now: now,
        email: 'parked-needs-review@example.com',
        status: 'needs_review'
      )

      travel_to now do
        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
            NotifyApplicationReview.call(now: now)
          end
        end
      end

      assert_nil application.reload.application_reminder_sent_at
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

    def train_staff(user)
      grant_privileges(user, 'applications.review')
    end
  end
end
