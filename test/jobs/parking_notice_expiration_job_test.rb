require 'test_helper'

class ParkingNoticeExpirationJobTest < ActiveJob::TestCase
  test 'expires active notices past their expiration date' do
    notice = parking_notices(:active_permit)
    notice.update!(expires_at: 1.hour.ago)

    ParkingNoticeExpirationJob.perform_now

    assert notice.reload.expired?
  end

  test 'does not expire active notices still in the future' do
    notice = parking_notices(:active_permit)
    assert notice.expires_at > Time.current

    ParkingNoticeExpirationJob.perform_now

    assert notice.reload.active?
  end

  test 'does not modify already cleared notices' do
    notice = parking_notices(:cleared_permit)

    ParkingNoticeExpirationJob.perform_now

    assert notice.reload.cleared?
  end

  test 'creates journal entry for expired notice with user' do
    notice = parking_notices(:active_permit)
    notice.update!(expires_at: 1.hour.ago)

    assert_difference 'Journal.count', 1 do
      ParkingNoticeExpirationJob.perform_now
    end

    journal = Journal.last
    assert_equal 'parking_notice_expired', journal.action
    assert_equal notice.user, journal.user
  end

  test 'enqueues expiration email for notice with user' do
    notice = parking_notices(:active_permit)
    notice.update!(expires_at: 1.hour.ago)
    ReminderSetting.find_or_create_by!(key: 'parking_notices') { |s| s.name = 'Parking'; s.enabled = true }

    assert_difference 'QueuedMail.count', 1 do
      ParkingNoticeExpirationJob.perform_now
    end
  end

  test 'does not enqueue email when reminders disabled' do
    notice = parking_notices(:active_permit)
    notice.update!(expires_at: 1.hour.ago)
    ReminderSetting.find_or_create_by!(key: 'parking_notices') { |s| s.name = 'Parking'; s.enabled = false }

    assert_no_difference 'QueuedMail.count' do
      ParkingNoticeExpirationJob.perform_now
    end

    assert notice.reload.expired?
  end

  test 'does not enqueue email for notice without user' do
    notice = parking_notices(:anonymous_ticket)
    notice.update!(expires_at: 1.hour.ago)

    assert_no_difference 'QueuedMail.count' do
      ParkingNoticeExpirationJob.perform_now
    end
  end
end
