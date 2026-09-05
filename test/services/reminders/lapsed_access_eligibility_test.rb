require 'test_helper'

module Reminders
  class LapsedAccessEligibilityTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 6, 8, 5, 0)
      MembershipSetting.instance.update!(reactivation_grace_period_months: 12)
      ReminderSetting.seed_defaults!
      @setting = ReminderSetting.find_by!(key: 'lapsed_access')
    end

    test 'due includes inactive members who badged in during the window' do
      user = inactive_user(email: 'accessed-yesterday@example.com')

      travel_to @now do
        assert_includes LapsedAccessEligibility.due(now: @now), user
        assert LapsedAccessEligibility.due?(user, now: @now)
      end
    end

    test 'due excludes overdue members even if they badged in' do
      user = inactive_user(email: 'overdue-not-inactive@example.com')
      user.update_columns(membership_state: 'overdue_member')

      travel_to @now do
        assert_not_includes LapsedAccessEligibility.due(now: @now), user.reload
        assert_not LapsedAccessEligibility.due?(user, now: @now)
      end
    end

    test 'due excludes members whose only visit is older than the window' do
      user = inactive_user(email: 'old-access@example.com', accessed_at: @now - 2.days)

      travel_to @now do
        assert_not_includes LapsedAccessEligibility.due(now: @now), user
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

    # ─── Configurable lookback ────────────────────────────────────────

    test 'window spans the configured number of days' do
      @setting.update!(lookback_days: 7)

      travel_to @now do
        window = LapsedAccessEligibility.window(now: @now)
        assert_equal @now - 7.days, window.begin
        assert_equal @now, window.end
      end
    end

    test 'a longer lookback reaches visits the default window misses' do
      user = inactive_user(email: 'five-days-ago@example.com', accessed_at: @now - 5.days)

      travel_to @now do
        assert_not_includes LapsedAccessEligibility.due(now: @now), user

        @setting.update!(lookback_days: 7)
        assert_includes LapsedAccessEligibility.due(now: @now), user
      end
    end

    test 'a shorter lookback drops visits that fall outside it' do
      @setting.update!(lookback_days: 10)
      user = inactive_user(email: 'eight-days-ago@example.com', accessed_at: @now - 8.days)

      travel_to @now do
        assert_includes LapsedAccessEligibility.due(now: @now), user

        @setting.update!(lookback_days: 2)
        assert_not_includes LapsedAccessEligibility.due(now: @now), user
      end
    end

    test 'lookback falls back to the default when the setting is missing' do
      ReminderSetting.where(key: 'lapsed_access').delete_all

      assert_equal LapsedAccessEligibility::DEFAULT_LOOKBACK_DAYS, LapsedAccessEligibility.lookback_days
    end

    # ─── Per-visit notification tracking ─────────────────────────────

    test 'due excludes members whose visits in the window were all already covered' do
      user = inactive_user(email: 'already-covered@example.com')
      AccessLog.where(user_id: user.id).update_all(lapsed_access_reminder_sent_at: @now - 2.hours)

      travel_to @now do
        assert_not_includes LapsedAccessEligibility.due(now: @now), user.reload
        assert_not LapsedAccessEligibility.due?(user, now: @now)
      end
    end

    test 'due includes a reminded member again once a new visit appears' do
      user = inactive_user(email: 'badged-in-again@example.com')
      AccessLog.where(user_id: user.id).update_all(lapsed_access_reminder_sent_at: @now - 1.day)
      user.update_columns(lapsed_access_reminder_sent_at: @now - 1.day)

      travel_to @now do
        assert_not LapsedAccessEligibility.due?(user.reload, now: @now)

        AccessLog.create!(user: user, logged_at: @now - 2.hours, name: user.display_name, action: 'opened')
        assert LapsedAccessEligibility.due?(user.reload, now: @now)
      end
    end

    test 'unnotified_access_log_ids returns only uncovered visits in the window' do
      user = inactive_user(email: 'mixed-visits@example.com')
      covered = AccessLog.where(user_id: user.id).first
      covered.update!(lapsed_access_reminder_sent_at: @now - 1.day)
      outside = AccessLog.create!(user: user, logged_at: @now - 5.days, name: user.display_name, action: 'opened')
      fresh = AccessLog.create!(user: user, logged_at: @now - 3.hours, name: user.display_name, action: 'opened')

      travel_to @now do
        ids = LapsedAccessEligibility.unnotified_access_log_ids(user, now: @now)

        assert_equal [fresh.id], ids
        assert_not_includes ids, covered.id
        assert_not_includes ids, outside.id
      end
    end

    test 'unnotified_access_counts reports one entry per member' do
      busy = inactive_user(email: 'six-visits@example.com')
      5.times { |i| AccessLog.create!(user: busy, logged_at: @now - (i + 2).hours, name: busy.display_name) }
      quiet = inactive_user(email: 'one-visit@example.com')

      travel_to @now do
        counts = LapsedAccessEligibility.unnotified_access_counts([busy.id, quiet.id], now: @now)

        assert_equal 6, counts[busy.id]
        assert_equal 1, counts[quiet.id]
      end
    end

    test 'unnotified_access_counts is empty without user ids' do
      assert_empty LapsedAccessEligibility.unnotified_access_counts([])
    end

    test 'total_accessed_in_window counts members already covered by a reminder' do
      travel_to @now do
        due_before = LapsedAccessEligibility.count_due(now: @now)
        window_before = LapsedAccessEligibility.total_accessed_in_window(now: @now)

        covered = inactive_user(email: 'covered-in-window@example.com')
        AccessLog.where(user_id: covered.id).update_all(lapsed_access_reminder_sent_at: @now - 2.hours)
        uncovered = inactive_user(email: 'uncovered-in-window@example.com')

        # Both are in the window, but only the uncovered one has anything left to say.
        assert_equal window_before + 2, LapsedAccessEligibility.total_accessed_in_window(now: @now)
        assert_equal due_before + 1, LapsedAccessEligibility.count_due(now: @now)
        assert_not_includes LapsedAccessEligibility.due(now: @now), covered
        assert_includes LapsedAccessEligibility.due(now: @now), uncovered
      end
    end

    private

    def inactive_user(email:, accessed_at: nil)
      accessed_at ||= @now - 1.hour
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
