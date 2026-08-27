require 'test_helper'

module Reminders
  class ParkingNoticeEligibilityTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 21, 7, 0, 0)
      @user = users(:one)
      @notice = parking_notices(:active_permit)
      @notice.update!(user: @user, expires_at: @now + 2.days, status: 'active')
      ReminderSetting.seed_defaults!
      MembershipSetting.instance.update!(
        parking_notice_reminder_days_before_expiration: 3,
        parking_notice_expired_reminder_repeat_days: 7,
        parking_notice_final_reminder_days_after_expiration: 14
      )
    end

    test 'pre_expiration due when inside reminder window' do
      travel_to @now do
        assert ParkingNoticeEligibility.pre_expiration_due?(@notice.reload, now: @now)
        assert_includes ParkingNoticeEligibility.due(now: @now), @notice
      end
    end

    test 'due excludes members who opted out of parking notices email' do
      ReminderSetting.find_by!(key: 'parking_notices').update!(allow_opt_out: true)
      NotificationOptOut.opt_out!(@user, category: 'parking_notices', channel: 'email')

      travel_to @now do
        assert_not_includes ParkingNoticeEligibility.due(now: @now), @notice.reload
      end
    end

    test 'pre_expiration not due when days before is zero' do
      MembershipSetting.instance.update!(parking_notice_reminder_days_before_expiration: 0)

      travel_to @now do
        assert_not ParkingNoticeEligibility.pre_expiration_due?(@notice.reload, now: @now)
      end
    end

    test 'expiration due when expired and past expires_at without notice sent' do
      @notice.update!(status: 'expired', expires_at: @now - 1.hour)

      travel_to @now do
        assert ParkingNoticeEligibility.expiration_due?(@notice.reload, now: @now)
      end
    end

    test 'expiration not due for active notices before expire job runs' do
      @notice.update!(status: 'active', expires_at: @now - 1.hour)

      travel_to @now do
        assert_not ParkingNoticeEligibility.expiration_due?(@notice.reload, now: @now)
      end
    end

    test 'cleared notices are not remindable' do
      @notice.update!(status: 'cleared', cleared_at: @now, cleared_by: @user)

      travel_to @now do
        assert_not ParkingNoticeEligibility.remindable?(@notice.reload)
        assert_not_includes ParkingNoticeEligibility.due(now: @now), @notice
      end
    end

    test 'final due after final reminder window' do
      @notice.update!(
        status: 'expired',
        expires_at: @now - 15.days,
        expiration_notice_sent_at: @now - 15.days
      )

      travel_to @now do
        assert ParkingNoticeEligibility.final_due?(@notice.reload, now: @now)
      end
    end

    test 'overdue repeat due after repeat interval' do
      @notice.update!(
        status: 'expired',
        expires_at: @now - 10.days,
        expiration_notice_sent_at: @now - 10.days,
        overdue_reminder_sent_at: @now - 8.days
      )

      travel_to @now do
        assert ParkingNoticeEligibility.overdue_repeat_due?(@notice.reload, now: @now)
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
        assert ParkingNoticeEligibility.pre_expiration_due?(@notice, now: @now)
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
