require 'test_helper'

module Reminders
  class ScheduleTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 9, 1, 7, 0, 0)
      @anchor = @now - 10.days
      @user = User.create!(email: 'cadence@example.com', full_name: 'Cadence Subject',
                           service_account: false, membership_state: 'current_member', payment_type: 'unknown')
      ReminderSetting.seed_defaults!
    end

    test 'the first reminder lands at the start offset from the anchor' do
      schedule = build_schedule(start_offset_days: 5, interval_days: 7)

      assert_equal @anchor + 5.days, schedule.next_due_at(@user, anchor: @anchor)
      assert schedule.due?(@user, anchor: @anchor, now: @anchor + 5.days)
      assert_not schedule.due?(@user, anchor: @anchor, now: @anchor + 5.days - 1.second)
    end

    # Parking warns people before their notice runs out, which is the whole reason the offset
    # is signed.
    test 'a negative start offset sends the first reminder before the anchor' do
      schedule = build_schedule(start_offset_days: -3, interval_days: 7)

      assert_equal @anchor - 3.days, schedule.next_due_at(@user, anchor: @anchor)
      assert schedule.due?(@user, anchor: @anchor, now: @anchor - 3.days)
      assert_not schedule.due?(@user, anchor: @anchor, now: @anchor - 4.days)
    end

    test 'an offset of zero sends the first reminder on the anchor itself' do
      schedule = build_schedule(start_offset_days: 0, interval_days: 1)

      assert_equal @anchor, schedule.next_due_at(@user, anchor: @anchor)
    end

    # From the last send rather than from the anchor, so a skipped run or mail held for review
    # pushes the rest of the sequence back instead of firing several at once to catch up.
    test 'later reminders are spaced an interval from the last one sent' do
      schedule = build_schedule(start_offset_days: 5, interval_days: 7)
      sent_at = @now - 2.days
      ReminderDelivery.record!('slack_signup', @user, anchor: @anchor, at: sent_at)

      assert_equal sent_at + 7.days, schedule.next_due_at(@user, anchor: @anchor)
      assert_not schedule.due?(@user, anchor: @anchor, now: @now)
      assert schedule.due?(@user, anchor: @anchor, now: sent_at + 7.days)
    end

    test 'nothing is due once the maximum has been sent' do
      schedule = build_schedule(start_offset_days: 1, interval_days: 1, max_reminders: 2)
      2.times { |i| ReminderDelivery.record!('slack_signup', @user, anchor: @anchor, at: @now - (5 - i).days) }

      assert_nil schedule.next_due_at(@user, anchor: @anchor)
      assert_not schedule.due?(@user, anchor: @anchor, now: @now + 1.year)
      assert schedule.exhausted?(2)
    end

    test 'a nil maximum keeps sending' do
      schedule = build_schedule(start_offset_days: 1, interval_days: 1, max_reminders: nil)
      50.times { |i| ReminderDelivery.record!('slack_signup', @user, anchor: @anchor, at: @now - (60 - i).days) }

      assert schedule.due?(@user, anchor: @anchor, now: @now)
      assert_not schedule.exhausted?(50)
    end

    test 'a moved anchor restarts the sequence at the first reminder' do
      schedule = build_schedule(start_offset_days: 2, interval_days: 30, max_reminders: 2)
      2.times { |i| ReminderDelivery.record!('slack_signup', @user, anchor: @anchor, at: @now - (5 - i).days) }
      new_anchor = @now - 3.days

      assert_equal 0, schedule.sent_count(@user, anchor: new_anchor)
      assert_equal new_anchor + 2.days, schedule.next_due_at(@user, anchor: new_anchor)
      assert schedule.due?(@user, anchor: new_anchor, now: @now)
    end

    # Rows backfilled from the old per-reminder timestamps have no anchor recorded. Reading
    # that as a restart would hand every one of them a fresh sequence.
    test 'a recorded delivery with no anchor continues its sequence' do
      schedule = build_schedule(start_offset_days: 2, interval_days: 7, max_reminders: 2)
      ReminderDelivery.create!(reminder_key: 'slack_signup', subject: @user, sent_count: 2,
                               first_sent_at: @now - 9.days, last_sent_at: @now - 2.days)

      assert_equal 2, schedule.sent_count(@user, anchor: @anchor)
      assert_nil schedule.next_due_at(@user, anchor: @anchor)
    end

    test 'nothing is due without an anchor to count from' do
      schedule = build_schedule(start_offset_days: 0, interval_days: 1)

      assert_nil schedule.next_due_at(@user, anchor: nil)
      assert_not schedule.due?(@user, anchor: nil, now: @now)
    end

    # Parking picks its final-notice template this way.
    test 'final_send? is true only on the last reminder of a limited sequence' do
      schedule = build_schedule(start_offset_days: 0, interval_days: 1, max_reminders: 3)

      assert_not schedule.final_send?(@user, anchor: @anchor)

      2.times { |i| ReminderDelivery.record!('slack_signup', @user, anchor: @anchor, at: @now - (5 - i).days) }

      assert schedule.final_send?(@user, anchor: @anchor)
    end

    test 'final_send? is never true without a maximum' do
      schedule = build_schedule(start_offset_days: 0, interval_days: 1, max_reminders: nil)
      5.times { |i| ReminderDelivery.record!('slack_signup', @user, anchor: @anchor, at: @now - (10 - i).days) }

      assert_not schedule.final_send?(@user, anchor: @anchor)
    end

    test 'description reads back the cadence in words' do
      assert_equal 'On approval, then daily, with no limit',
                   build_schedule(start_offset_days: 0, interval_days: 1).description
      assert_equal '5 days after approval, then every 7 days, up to 3 reminders',
                   build_schedule(start_offset_days: 5, interval_days: 7, max_reminders: 3).description
      assert_equal '3 days before approval, then every 2 days, up to 1 reminder',
                   build_schedule(start_offset_days: -3, interval_days: 2, max_reminders: 1).description
    end

    private

    # slack_signup stands in for any reminder: the cadence knows nothing about which one it is.
    def build_schedule(**cadence)
      Schedule.new(set_reminder_cadence('slack_signup', **cadence))
    end
  end
end
