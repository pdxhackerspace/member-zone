require 'test_helper'

module Reminders
  class LapsedAccessEligibilityTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 6, 8, 5, 0)
      MembershipSetting.instance.update!(reactivation_grace_period_months: 12)
    end

    test 'due includes inactive members who accessed yesterday' do
      user = inactive_user(email: 'accessed-yesterday@example.com')

      travel_to @now do
        assert_includes LapsedAccessEligibility.due(now: @now), user
        assert LapsedAccessEligibility.due?(user, now: @now)
      end
    end

    test 'due excludes overdue members even if they accessed yesterday' do
      user = inactive_user(email: 'overdue-not-inactive@example.com')
      user.update_columns(membership_state: 'overdue_member')

      travel_to @now do
        assert_not_includes LapsedAccessEligibility.due(now: @now), user.reload
        assert_not LapsedAccessEligibility.due?(user, now: @now)
      end
    end

    test 'due excludes inactive members whose access was not yesterday' do
      user = inactive_user(email: 'old-access@example.com', accessed_at: @now - 2.days)

      travel_to @now do
        assert_not_includes LapsedAccessEligibility.due(now: @now), user
      end
    end

    test 'due excludes inactive members already reminded today' do
      user = inactive_user(email: 'already-reminded@example.com')
      user.update_columns(lapsed_access_reminder_sent_at: @now - 1.hour)

      travel_to @now do
        assert_not_includes LapsedAccessEligibility.due(now: @now), user.reload
      end
    end

    test 'due excludes members who cancelled' do
      user = inactive_user(email: 'cancelled-inactive@example.com')
      user.note_cancellation!

      travel_to @now do
        assert_not_includes LapsedAccessEligibility.due(now: @now), user.reload
      end
    end

    test 'due excludes members with reminder mail awaiting review' do
      user = inactive_user(email: 'awaiting-review@example.com')
      QueuedMail.create!(
        recipient: user,
        to: user.email,
        subject: 'Pending',
        body_html: '<p>Hi</p>',
        body_text: 'Hi',
        reason: 'Test',
        mailer_action: 'lapsed_access_reminder',
        status: 'pending'
      )

      travel_to @now do
        assert_not_includes LapsedAccessEligibility.due(now: @now), user
      end
    end

    private

    def inactive_user(email:, accessed_at: nil)
      accessed_at ||= @now - 1.day
      user = User.create!(
        email: email,
        full_name: 'Inactive Access User',
        service_account: false,
        membership_state: 'inactive_member',
        payment_type: 'unknown',
        last_payment_date: (@now - 30.days).to_date
      )
      user.update_columns(membership_state_entered_at: @now - 45.days)
      AccessLog.create!(user: user, logged_at: accessed_at, name: user.display_name, action: 'opened')
      user
    end
  end
end
