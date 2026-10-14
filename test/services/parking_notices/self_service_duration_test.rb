require 'test_helper'

module ParkingNotices
  class SelfServiceDurationTest < ActiveSupport::TestCase
    test 'a new permit within the maximum passes' do
      notice = ParkingNotice.new(expires_at: 13.days.from_now)
      SelfServiceDuration.validate(notice)

      assert_empty notice.errors
    end

    test 'a new permit past the maximum fails' do
      notice = ParkingNotice.new(expires_at: 15.days.from_now)
      SelfServiceDuration.validate(notice)

      assert_includes notice.errors[:expires_at], 'must be within 2 weeks'
    end

    test 'the maximum counts from creation for an existing permit' do
      notice = parking_notices(:active_permit)
      notice.update_columns(created_at: 10.days.ago)
      notice.expires_at = 6.days.from_now
      SelfServiceDuration.validate(notice)

      assert notice.errors[:expires_at].any?
    end

    test 'an unchanged expiry is not judged even when past the maximum' do
      notice = parking_notices(:active_permit)
      notice.update_columns(expires_at: 40.days.from_now.change(sec: 0))
      notice.expires_at = notice.expires_at + 20.seconds
      SelfServiceDuration.validate(notice)

      assert_empty notice.errors
    end

    test 'a blank expiry is left to the model validation' do
      notice = ParkingNotice.new(expires_at: nil)
      SelfServiceDuration.validate(notice)

      assert_empty notice.errors
    end
  end
end
