require 'test_helper'

module Reminders
  class ParkingNoticeEligibilityTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 21, 7, 0, 0)
      @user = users(:one)
      @notice = parking_notices(:active_permit)
      @notice.update!(user: @user, expires_at: @now + 2.days, status: 'active')
      set_reminder_cadence('parking_notices', start_offset_days: -3, interval_days: 7, max_reminders: 4)
    end

    test 'the first reminder is due inside the pre-expiration window' do
      travel_to @now do
        assert ParkingNoticeEligibility.due?(@notice.reload, now: @now)
        assert_equal :pre_expiration, ParkingNoticeEligibility.phase_for(@notice, now: @now)
        assert_includes ParkingNoticeEligibility.due(now: @now), @notice
      end
    end

    test 'nothing is due before the pre-expiration window opens' do
      @notice.update!(expires_at: @now + 10.days)

      travel_to @now do
        assert_not ParkingNoticeEligibility.due?(@notice.reload, now: @now)
        assert_nil ParkingNoticeEligibility.phase_for(@notice, now: @now)
      end
    end

    test 'due excludes members who opted out of parking notices email' do
      ReminderSetting.find_by!(key: 'parking_notices').update!(allow_opt_out: true)
      NotificationOptOut.opt_out!(@user, category: 'parking_notices', channel: 'email')

      travel_to @now do
        assert_not_includes ParkingNoticeEligibility.due(now: @now), @notice.reload
      end
    end

    # A zero offset is how an admin turns the advance warning off: the first email then lands
    # on the expiration date and reads as the expiration notice.
    test 'a zero start offset skips the pre-expiration warning' do
      set_reminder_cadence('parking_notices', start_offset_days: 0)

      travel_to @now do
        assert_not ParkingNoticeEligibility.due?(@notice.reload, now: @now)
      end

      travel_to @notice.expires_at do
        assert_equal :expiration, ParkingNoticeEligibility.phase_for(@notice.reload, now: @notice.expires_at)
      end
    end

    test 'the first send after expiration is the expiration notice' do
      @notice.update!(status: 'expired', expires_at: @now - 1.hour)
      record_reminder_sent('parking_notices', @notice, at: @now - 8.days)

      travel_to @now do
        assert_equal :expiration, ParkingNoticeEligibility.phase_for(@notice.reload, now: @now)
      end
    end

    test 'sends between the expiration notice and the last one are follow-ups' do
      @notice.update!(status: 'expired', expires_at: @now - 10.days)
      record_reminder_sent('parking_notices', @notice, at: @now - 8.days, times: 2)

      travel_to @now do
        assert_equal :overdue, ParkingNoticeEligibility.phase_for(@notice.reload, now: @now)
      end
    end

    # The final notice is the last send in the sequence rather than a fixed number of days
    # after expiration, which is why parking needs a maximum set.
    test 'the last send in the sequence is the final notice' do
      @notice.update!(status: 'expired', expires_at: @now - 20.days)
      record_reminder_sent('parking_notices', @notice, at: @now - 8.days, times: 3)

      travel_to @now do
        assert_equal :final, ParkingNoticeEligibility.phase_for(@notice.reload, now: @now)
      end
    end

    test 'nothing is due once the maximum has been sent' do
      @notice.update!(status: 'expired', expires_at: @now - 30.days)
      record_reminder_sent('parking_notices', @notice, at: @now - 8.days, times: 4)

      travel_to @now do
        assert_not ParkingNoticeEligibility.due?(@notice.reload, now: @now)
        assert_not_includes ParkingNoticeEligibility.due(now: @now), @notice
      end
    end

    # Extending a notice is a new anchor, so the member hears the whole sequence again rather
    # than nothing at all.
    test 'extending a notice starts the sequence over' do
      @notice.update!(status: 'expired', expires_at: @now - 30.days)
      record_reminder_sent('parking_notices', @notice, at: @now - 8.days, times: 4)
      @notice.update!(status: 'active', expires_at: @now + 2.days)

      travel_to @now do
        assert ParkingNoticeEligibility.due?(@notice.reload, now: @now)
        assert_equal :pre_expiration, ParkingNoticeEligibility.phase_for(@notice, now: @now)
        assert_includes ParkingNoticeEligibility.due(now: @now), @notice
      end
    end

    test 'nothing is due inside the interval since the last reminder' do
      @notice.update!(status: 'expired', expires_at: @now - 10.days)
      record_reminder_sent('parking_notices', @notice, at: @now - 2.days)

      travel_to @now do
        assert_not ParkingNoticeEligibility.due?(@notice.reload, now: @now)
      end
    end

    test 'cleared notices are not remindable' do
      @notice.update!(status: 'cleared', cleared_at: @now, cleared_by: @user)

      travel_to @now do
        assert_not ParkingNoticeEligibility.remindable?(@notice.reload)
        assert_not_includes ParkingNoticeEligibility.due(now: @now), @notice
      end
    end

    test 'banned members are not remindable' do
      @user.update_columns(membership_state: 'banned_member')

      travel_to @now do
        assert_not ParkingNoticeEligibility.remindable?(@notice.reload)
        assert_not_includes ParkingNoticeEligibility.due(now: @now), @notice
      end
    end

    test 'pending issued mail does not block reminder eligibility' do
      QueuedMail.create!(
        to: @user.email,
        subject: 'Parking permit issued',
        body_html: '<p>Issued</p>',
        body_text: 'Issued',
        reason: 'Parking permit issued',
        mailer_action: 'parking_permit_issued',
        recipient: @user,
        status: 'pending',
        mailer_args: { parking_notice_id: @notice.id }
      )

      travel_to @now do
        assert ParkingNoticeEligibility.remindable?(@notice.reload)
        assert ParkingNoticeEligibility.due?(@notice, now: @now)
      end
    end

    test 'pending reminder mail blocks duplicate reminders' do
      QueuedMail.create!(
        to: @user.email,
        subject: 'Expiring soon',
        body_html: '<p>Soon</p>',
        body_text: 'Soon',
        reason: 'Parking permit expiring soon',
        mailer_action: 'parking_permit_expiring_soon',
        recipient: @user,
        status: 'pending',
        mailer_args: { parking_notice_id: @notice.id }
      )

      travel_to @now do
        assert_not ParkingNoticeEligibility.remindable?(@notice.reload)
      end
    end
  end
end
