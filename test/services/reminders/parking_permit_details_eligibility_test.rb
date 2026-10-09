require 'test_helper'

class ParkingPermitDetailsEligibilityTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    set_reminder_cadence('parking_permit_details', enabled: true, start_offset_days: 1, interval_days: 2,
                                                   max_reminders: 3)
    @member = users(:one)
    @device = WebhookDevice.create!(name: 'Front door kiosk')
  end

  test 'a blank permit is due a day after it was issued' do
    notice = blank_permit(issued_at: 2.days.ago)

    assert_includes Reminders::ParkingPermitDetailsEligibility.due, notice
  end

  test 'a permit issued today is not due yet' do
    notice = blank_permit(issued_at: 1.hour.ago)

    assert_not_includes Reminders::ParkingPermitDetailsEligibility.due, notice
  end

  test 'a permit with its details filled in is not due' do
    notice = blank_permit(issued_at: 2.days.ago)
    notice.update!(description: 'Bookshelf', location: 'Woodshop')

    assert_not notice.awaiting_details?
    assert_not_includes Reminders::ParkingPermitDetailsEligibility.due, notice
  end

  test 'a cleared permit is not due' do
    notice = blank_permit(issued_at: 2.days.ago)
    notice.clear!(@member)

    assert_not_includes Reminders::ParkingPermitDetailsEligibility.due, notice
  end

  test 'stops after the maximum number of reminders' do
    notice = blank_permit(issued_at: 10.days.ago)
    record_reminder_sent('parking_permit_details', notice, at: 5.days.ago, times: 3)

    assert_not_includes Reminders::ParkingPermitDetailsEligibility.due, notice
  end

  test 'the run emails a fresh link and counts the send' do
    notice = blank_permit(issued_at: 2.days.ago)

    assert_difference -> { ParkingPermitLink.where(parking_notice: notice).count }, 1 do
      assert_enqueued_emails 1 do
        Reminders::NotifyParkingPermitDetails.call
      end
    end

    assert_equal 1, Reminders::ParkingPermitDetailsEligibility.reminders_sent(notice)
    assert_not_includes Reminders::ParkingPermitDetailsEligibility.due, notice
  end

  test 'the run sends nothing when the reminder is disabled' do
    blank_permit(issued_at: 2.days.ago)
    set_reminder_cadence('parking_permit_details', enabled: false)

    assert_no_enqueued_emails do
      Reminders::NotifyParkingPermitDetails.call
    end
  end

  private

  def blank_permit(issued_at:)
    ParkingNotice.create!(notice_type: 'permit', status: 'active', members: [@member], issued_by: @member,
                          webhook_device: @device, expires_at: issued_at + 2.weeks,
                          details_requested_at: issued_at)
  end
end
