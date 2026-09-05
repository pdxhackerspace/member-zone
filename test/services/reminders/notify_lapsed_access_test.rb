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
      create_template(send_immediately: true)
    end

    teardown do
      clear_enqueued_jobs
    end

    test 'does nothing when reminder is disabled' do
      @setting.update!(enabled: false)
      inactive_user(email: 'disabled@example.com')

      travel_to @now do
        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          run_reminder
        end
      end
    end

    test 'emails inactive members who badged in during the window' do
      user = inactive_user(email: 'notify-me@example.com')

      travel_to @now do
        assert_difference 'ActionMailer::Base.deliveries.size', 1 do
          run_reminder
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
        run_reminder
      end

      assert_includes ActionMailer::Base.deliveries.last.text_part.body.decoded, 'reactivation window has passed'
    end

    test 'does not email inactive members whose visits predate the window' do
      inactive_user(email: 'no-recent-access@example.com', accessed_at: @now - 2.days)

      travel_to @now do
        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          run_reminder
        end
      end
    end

    # ─── One email per batch of visits ───────────────────────────────

    test 'six visits produce one email and stamp all six entries' do
      user = inactive_user(email: 'six-visits@example.com')
      5.times { |i| AccessLog.create!(user: user, logged_at: @now - (i + 2).hours, name: user.display_name) }
      assert_equal 6, AccessLog.where(user_id: user.id).count

      travel_to @now do
        assert_difference 'ActionMailer::Base.deliveries.size', 1 do
          run_reminder
        end
      end

      assert_equal 6, AccessLog.where(user_id: user.id).where.not(lapsed_access_reminder_sent_at: nil).count
      assert_empty AccessLog.where(user_id: user.id).lapsed_access_unnotified
    end

    test 'a second run the same day sends nothing more' do
      inactive_user(email: 'run-twice@example.com')

      travel_to @now do
        run_reminder

        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          run_reminder
        end
      end
    end

    test 'a new visit the next day earns another reminder' do
      user = inactive_user(email: 'again-tomorrow@example.com')

      travel_to @now do
        assert_difference 'ActionMailer::Base.deliveries.size', 1 do
          run_reminder
        end
      end

      tomorrow = @now + 1.day
      AccessLog.create!(user: user, logged_at: tomorrow - 3.hours, name: user.display_name, action: 'opened')

      travel_to tomorrow do
        assert_difference 'ActionMailer::Base.deliveries.size', 1 do
          run_reminder(now: tomorrow)
        end
      end

      assert_equal tomorrow, user.reload.lapsed_access_reminder_sent_at
      assert_empty AccessLog.where(user_id: user.id).lapsed_access_unnotified
    end

    test 'no new visit the next day means no second reminder' do
      inactive_user(email: 'quiet-tomorrow@example.com')

      travel_to @now do
        run_reminder
      end

      tomorrow = @now + 1.day
      travel_to tomorrow do
        assert_no_difference 'ActionMailer::Base.deliveries.size' do
          run_reminder(now: tomorrow)
        end
      end
    end

    test 'a longer lookback covers older visits in the same single email' do
      @setting.update!(lookback_days: 7)
      user = inactive_user(email: 'week-of-visits@example.com', accessed_at: @now - 6.days)
      AccessLog.create!(user: user, logged_at: @now - 4.days, name: user.display_name)
      AccessLog.create!(user: user, logged_at: @now - 2.hours, name: user.display_name)

      travel_to @now do
        assert_difference 'ActionMailer::Base.deliveries.size', 1 do
          run_reminder
        end
      end

      assert_equal 3, AccessLog.where(user_id: user.id).where.not(lapsed_access_reminder_sent_at: nil).count
    end

    test 'visits outside the window are left untouched' do
      user = inactive_user(email: 'partly-outside@example.com')
      stale = AccessLog.create!(user: user, logged_at: @now - 9.days, name: user.display_name)

      travel_to @now do
        run_reminder
      end

      assert_nil stale.reload.lapsed_access_reminder_sent_at
    end

    # ─── Mail held for review ────────────────────────────────────────

    test 'queued mail records the visits it described, not the window at send time' do
      create_template(send_immediately: false)
      user = inactive_user(email: 'held-for-review@example.com')
      AccessLog.create!(user: user, logged_at: @now - 2.hours, name: user.display_name)

      travel_to @now do
        run_reminder
      end

      queued = QueuedMail.find_by!(recipient: user, mailer_action: 'lapsed_access_reminder')
      described_ids = queued.mailer_args['access_log_ids']
      assert_equal 2, described_ids.size
      assert_equal 2,
                   AccessLog.where(user_id: user.id).lapsed_access_unnotified.count,
                   'visits must stay open until the reminder is actually sent'

      # A visit that lands while the mail waits for review is not covered by it.
      later = AccessLog.create!(user: user, logged_at: @now + 6.hours, name: user.display_name)
      sent_at = @now + 12.hours
      travel_to sent_at do
        queued.approve!(users(:one))
        perform_enqueued_jobs only: [QueuedMailDeliveryJob, ActionMailer::MailDeliveryJob]
      end

      assert_equal described_ids.sort, AccessLog.where(user_id: user.id)
                                                .where.not(lapsed_access_reminder_sent_at: nil)
                                                .pluck(:id).sort
      assert_nil later.reload.lapsed_access_reminder_sent_at
      assert_equal sent_at, user.reload.lapsed_access_reminder_sent_at
    end

    test 'a member with mail awaiting review is not queued again' do
      create_template(send_immediately: false)
      user = inactive_user(email: 'no-double-queue@example.com')

      travel_to @now do
        run_reminder
        AccessLog.create!(user: user, logged_at: @now + 1.hour, name: user.display_name)

        assert_no_difference -> { QueuedMail.where(recipient: user).count } do
          run_reminder(now: @now + 2.hours)
        end
      end
    end

    test 'the queue reason names how many visits prompted the email' do
      create_template(send_immediately: false)
      user = inactive_user(email: 'reason-line@example.com')
      2.times { |i| AccessLog.create!(user: user, logged_at: @now - (i + 2).hours, name: user.display_name) }

      travel_to @now do
        run_reminder
      end

      queued = QueuedMail.find_by!(recipient: user, mailer_action: 'lapsed_access_reminder')
      assert_includes queued.reason, '3 times'
    end

    private

    def run_reminder(now: @now)
      perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
        NotifyLapsedAccess.call(now: now)
      end
    end

    def create_template(send_immediately:)
      EmailTemplate.where(key: 'lapsed_access_reminder').delete_all
      EmailTemplate.create!(
        key: 'lapsed_access_reminder',
        name: 'Lapsed Member Access Reminder',
        subject: 'Lapsed {{member_name}} on {{lapsed_at}}',
        body_html: '<p>{{reactivation_guidance_html}}</p><p>{{profile_url}}</p>',
        body_text: "{{reactivation_guidance_text}}\n{{profile_url}}",
        enabled: true,
        send_immediately: send_immediately
      )
    end

    def inactive_user(email:, accessed_at: nil, last_payment: nil)
      accessed_at ||= @now - 1.hour
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
