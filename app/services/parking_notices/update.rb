module ParkingNotices
  # Changes a notice's details and, when +member_ids+ is given, its member list. A nil
  # +member_ids+ leaves the members alone. Members newly added are told about the notice.
  class Update
    def self.call(...)
      new(...).call
    end

    def initialize(notice:, actor:, attributes:, member_ids: nil, self_service: false)
      @notice = notice
      @actor = actor
      @attributes = attributes
      @member_ids = member_ids
      @self_service = self_service
    end

    def call
      @notice.event_actor = @actor
      @notice.assign_attributes(@attributes)
      SelfServiceDuration.validate(@notice) if @self_service
      return invalid unless @notice.errors.empty?

      newly_added = save_with_members!
      @notice.notify_issued!(newly_added) if newly_added.any?
      Result.new(notice: @notice, newly_added: newly_added)
    rescue ActiveRecord::RecordInvalid
      invalid
    end

    private

    def save_with_members!
      ParkingNotice.transaction do
        @notice.save!
        next [] if @member_ids.nil?

        @notice.replace_members!(resolved_member_ids)
      end
    end

    def resolved_member_ids
      return MemberResolution.for_self_service(@member_ids, @actor, @notice) if @self_service

      MemberResolution.normalize(@member_ids)
    end

    def invalid
      Result.new(notice: @notice, error: :invalid)
    end
  end
end
