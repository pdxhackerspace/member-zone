module ParkingNotices
  # Issues a permit or ticket. Staff may issue either kind to anyone; a member issuing for
  # themselves (+self_service+) only gets a permit, capped at the self-service duration, with
  # themselves always on it.
  class Issue
    def self.call(...)
      new(...).call
    end

    def initialize(actor:, attributes:, member_ids:, self_service: false)
      @actor = actor
      @attributes = attributes
      @member_ids = member_ids
      @self_service = self_service
    end

    def call
      notice = build_notice
      return Result.new(notice: notice, error: :invalid) unless notice.errors.empty? && notice.save

      notice.record_journal_entry!(notice.permit? ? 'parking_permit_issued' : 'parking_ticket_issued', actor: @actor)
      notice.notify_issued!
      Result.new(notice: notice)
    end

    private

    def build_notice
      notice = ParkingNotice.new(@attributes)
      notice.issued_by = @actor
      notice.event_actor = @actor
      if @self_service
        notice.notice_type = 'permit'
        notice.status = 'active'
        notice.build_members_from_ids!(MemberResolution.for_self_service(@member_ids, @actor))
        SelfServiceDuration.validate(notice)
      else
        notice.build_members_from_ids!(MemberResolution.normalize(@member_ids))
      end
      notice
    end
  end
end
