module ParkingNotices
  # Removes one photo from a notice and says so in its history.
  class RemovePhoto
    def self.call(...)
      new(...).call
    end

    def initialize(notice:, actor:, photo:)
      @notice = notice
      @actor = actor
      @photo = photo
    end

    def call
      filename = @photo.filename.to_s
      @photo.purge
      note = "Removed photo #{filename}."
      @notice.log_event!('note', actor: @actor, note: note)
      @notice.record_journal_entry!('parking_notice_photo_removed', actor: @actor, note: note)
      Result.new(notice: @notice)
    end
  end
end
