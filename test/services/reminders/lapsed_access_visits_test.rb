require 'test_helper'

module Reminders
  class LapsedAccessVisitsTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 9, 5, 8, 5, 0)
      # A fixture member comes with access logs of its own, which would be indistinguishable from
      # the visits under test.
      @user = User.create!(
        email: 'visit-summary@example.com',
        full_name: 'Visit Summary User',
        service_account: false,
        membership_state: 'inactive_member',
        payment_type: 'unknown'
      )
      ReminderSetting.seed_defaults!
      ReminderSetting.find_by(key: 'lapsed_access').update!(lookback_days: 1)
    end

    test 'a single visit earlier today reads as today, not yesterday' do
      log_access(@now - 3.hours)

      assert_equal 'today', summary
    end

    test 'a single visit the day before reads as yesterday' do
      log_access(@now - 20.hours)

      assert_equal 'yesterday', summary
    end

    test 'a single older visit is named by date' do
      widen_window_to 10
      log_access(@now - 4.days)

      assert_equal 'on September 1', summary
    end

    # Reachable by id rather than by window, since the window caps out well short of a year.
    test 'a visit in an earlier year carries the year' do
      visit = log_access(Time.zone.local(2025, 12, 30, 19, 0, 0))

      assert_equal 'on December 30, 2025', summary(access_log_ids: [visit.id])
    end

    test 'several visits on one day are counted' do
      log_access(@now - 5.hours)
      log_access(@now - 3.hours)
      log_access(@now - 1.hour)

      assert_equal '3 times today', summary
    end

    test 'visits spread over days are given as a range' do
      widen_window_to 14
      log_access(@now - 6.days)
      log_access(@now - 4.days)
      log_access(@now - 2.days)

      assert_equal '3 times between August 30 and September 3', summary
    end

    test 'named ids win over the window so a held message keeps describing its own visits' do
      widen_window_to 14
      described = log_access(@now - 5.days)
      log_access(@now - 1.hour)

      assert_equal 'on August 31', summary(access_log_ids: [described.id])
    end

    test 'visits outside the window are not described' do
      log_access(@now - 5.days)

      assert_equal Reminders::LapsedAccessVisits::UNKNOWN, summary
    end

    test 'a member with no visits at all falls back to a vague phrase' do
      assert_equal 'recently', summary
    end

    # Regenerating or previewing a message after its visits were stamped must still describe them.
    test 'already notified visits are described when nothing is outstanding' do
      log_access(@now - 2.hours, notified_at: @now)

      assert_equal 'today', summary
    end

    private

    def summary(access_log_ids: nil)
      LapsedAccessVisits.summary(@user, access_log_ids: access_log_ids, now: @now)
    end

    def log_access(at, notified_at: nil)
      AccessLog.create!(user: @user, logged_at: at, name: @user.display_name, action: 'opened',
                        lapsed_access_reminder_sent_at: notified_at)
    end

    def widen_window_to(days)
      ReminderSetting.find_by(key: 'lapsed_access').update!(lookback_days: days)
    end
  end
end
