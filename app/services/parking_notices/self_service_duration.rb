module ParkingNotices
  # A member may give themselves a permit of at most ParkingNotice::MAX_SELF_SERVICE_DURATION,
  # counted from when the permit was created. Staff extensions and legacy permits may already run
  # past that, so an edit that leaves the expiry alone is never refused for it.
  module SelfServiceDuration
    module_function

    def validate(notice)
      return if notice.expires_at.blank?
      return if notice.persisted? && !expiry_changed?(notice)
      return if notice.expires_at <= max_expires_at(notice)

      notice.errors.add(:expires_at, 'must be within 2 weeks')
    end

    def max_expires_at(notice)
      anchor = notice.persisted? ? notice.created_at : Time.current
      anchor + ParkingNotice::MAX_SELF_SERVICE_DURATION
    end

    # Forms submit to the minute, so a resubmitted form with the same expiry is not a change.
    def expiry_changed?(notice)
      old_at = notice.expires_at_in_database
      return true if old_at.nil?

      to_minute(notice.expires_at) != to_minute(old_at)
    end

    def to_minute(time)
      time.in_time_zone.change(sec: 0, usec: 0)
    end
  end
end
