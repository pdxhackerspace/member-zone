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

      changed = changed_parts { save_with_members! }
      if changed.any?
        @notice.record_journal_entry!('parking_notice_updated', actor: @actor, note: "Changed #{changed.to_sentence}.")
      end
      @notice.notify_issued!(@newly_added) if @newly_added.any?
      Result.new(notice: @notice, newly_added: @newly_added)
    rescue ActiveRecord::RecordInvalid
      invalid
    end

    private

    # What the save changed, in words: fields, photos, and the member list.
    def changed_parts
      photos_changed = @notice.attachment_changes.key?('photos')
      members_before = @notice.member_ids.sort
      @newly_added = yield
      parts = @notice.journaled_field_changes
      parts << 'photos' if photos_changed
      parts << 'members' if @notice.members.reload.ids.sort != members_before
      parts
    end

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
