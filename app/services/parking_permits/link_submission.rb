module ParkingPermits
  # Applies the no-login permit form to the permit its link reaches. A +create_permit+ link makes
  # the permit (once); a +complete_permit+ link fills in what was parked and where on the blank
  # permit a device issued, leaving its expiry alone.
  #
  # Returns the parking notice; it carries errors when nothing was saved.
  class LinkSubmission
    def self.call(link, attributes, now: Time.current)
      new(link, attributes, now).call
    end

    def initialize(link, attributes, now)
      @link = link
      @attributes = attributes
      @now = now
    end

    def call
      @link.create_permit? ? create_permit : complete_permit
    end

    private

    def create_permit
      notice = ParkingNotice.new(@attributes.merge(notice_type: 'permit', status: 'active', members: [@link.user],
                                                   issued_by: @link.user, webhook_device: @link.webhook_device))
      return notice unless valid_details?(notice) && valid_expiry?(notice)

      ParkingNotice.transaction do
        notice.save!
        @link.update!(parking_notice: notice, submitted_at: @now)
      end
      notice.record_journal_entry!('parking_permit_issued', actor: @link.user)
      notice.notify_issued!
      notice
    end

    def complete_permit
      notice = @link.parking_notice
      notice.event_actor = @link.user
      notice.assign_attributes(@attributes)
      return notice unless valid_details?(notice)

      ParkingNotice.transaction do
        notice.save!
        notice.log_event!('note', actor: @link.user, note: 'Details filled in from the emailed permit link.')
        @link.update!(submitted_at: @now)
      end
      notice
    end

    # Whatever the form is for, a permit nobody can identify is no use to the space.
    def valid_details?(notice)
      notice.errors.add(:description, "can't be blank") if notice.description.blank?
      notice.errors.add(:location, "can't be blank") if notice.location.blank?
      notice.errors.empty?
    end

    def valid_expiry?(notice)
      if notice.expires_at.blank?
        notice.errors.add(:expires_at, "can't be blank")
      elsif notice.expires_at <= @now
        notice.errors.add(:expires_at, 'must be in the future')
      elsif notice.expires_at > @now + ParkingNotice::MAX_SELF_SERVICE_DURATION
        notice.errors.add(:expires_at, 'must be within 2 weeks')
      end
      notice.errors.empty?
    end
  end
end
