require 'test_helper'

class NotifyParkingNoticesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @now = Time.zone.local(2026, 8, 21, 7, 0, 0)
    ReminderSetting.seed_defaults!
    @setting = ReminderSetting.find_by!(key: 'parking_notices')
    @notice = parking_notices(:active_permit)
    @notice.update!(expires_at: @now - 1.hour)
  end

  def clear_other_parking_notices!(keep)
    ParkingNotice.where.not(id: keep.id).update_all(status: 'cleared', cleared_at: Time.current)
  end

  test 'expires notices when reminders disabled without emailing' do
    @setting.update!(enabled: false)
    clear_other_parking_notices!(@notice)

    travel_to @now do
      assert_no_difference 'QueuedMail.count' do
        Reminders::NotifyParkingNotices.call(now: @now)
      end
    end

    assert @notice.reload.expired?
  end

  test 'expires and enqueues expiration email when reminders enabled' do
    @setting.update!(enabled: true)
    clear_other_parking_notices!(@notice)

    travel_to @now do
      assert_difference 'QueuedMail.count', 1 do
        Reminders::NotifyParkingNotices.call(now: @now)
      end
    end

    assert @notice.reload.expired?
    mail = QueuedMail.order(:created_at).last
    assert_equal 'parking_permit_expired', mail.mailer_action
    assert_nil @notice.expiration_notice_sent_at
  end

  test 'sends pre-expiration reminder for active notice in window' do
    @setting.update!(enabled: true)
    @notice.update!(status: 'active', expires_at: @now + 2.days, pre_expiration_reminder_sent_at: nil)
    clear_other_parking_notices!(@notice)

    travel_to @now do
      notice = @notice.reload
      assert Reminders::ParkingNoticeEligibility.due?(notice, now: @now)

      assert_difference 'QueuedMail.count', 1 do
        Reminders::NotifyParkingNotices.call(now: @now)
      end
    end

    assert @notice.reload.active?
    assert_nil @notice.pre_expiration_reminder_sent_at
  end

  test 'expires anonymous tickets when reminders enabled' do
    @setting.update!(enabled: true)
    notice = parking_notices(:anonymous_ticket)
    notice.update!(status: 'active', expires_at: @now - 1.hour, cleared_at: nil, cleared_by_id: nil)
    clear_other_parking_notices!(notice)

    travel_to @now do
      assert_no_difference 'QueuedMail.count' do
        Reminders::NotifyParkingNotices.call(now: @now)
      end
    end

    assert notice.reload.expired?
  end

  test 'sends expiration email for notice expired while reminders were disabled' do
    @setting.update!(enabled: true)
    @notice.update!(status: 'expired', expires_at: @now - 1.hour, expiration_notice_sent_at: nil)
    clear_other_parking_notices!(@notice)

    travel_to @now do
      assert_difference 'QueuedMail.count', 1 do
        Reminders::NotifyParkingNotices.call(now: @now)
      end
    end

    assert_equal 'parking_permit_expired', QueuedMail.order(:created_at).last.mailer_action
  end

  test 'does not enqueue repeat mail for banned members' do
    @setting.update!(enabled: true)
    @notice.update!(status: 'expired', expires_at: @now - 1.hour, expiration_notice_sent_at: nil)
    @notice.user.update_columns(membership_state: 'banned_member')
    clear_other_parking_notices!(@notice)

    travel_to @now do
      assert_no_difference 'QueuedMail.count' do
        Reminders::NotifyParkingNotices.call(now: @now)
        Reminders::NotifyParkingNotices.call(now: @now)
      end
    end
  end
end
