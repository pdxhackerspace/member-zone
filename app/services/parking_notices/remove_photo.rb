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
      @notice.log_event!('note', actor: @actor, note: "Removed photo #{filename}.")
      Result.new(notice: @notice)
    end
  end
end
