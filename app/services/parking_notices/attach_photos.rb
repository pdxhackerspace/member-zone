module ParkingNotices
  # Adds photos to a notice. Only images, and only so many at once, so an API client cannot turn
  # a notice into file storage.
  class AttachPhotos
    MAX_PER_REQUEST = 10
    MAX_BYTES = 15.megabytes

    def self.call(...)
      new(...).call
    end

    def initialize(notice:, actor:, photos:)
      @notice = notice
      @actor = actor
      @photos = Array(photos).compact_blank
    end

    def call
      problem = validation_problem
      return Result.new(notice: @notice, error: :invalid_photo, message: problem) if problem

      @notice.photos.attach(@photos)
      @notice.log_event!('note', actor: @actor, note: "Added #{@photos.size} #{'photo'.pluralize(@photos.size)}.")
      Result.new(notice: @notice)
    end

    private

    def validation_problem
      return 'Attach at least one photo.' if @photos.empty?
      return "Attach at most #{MAX_PER_REQUEST} photos at a time." if @photos.size > MAX_PER_REQUEST
      return 'Photos must be images.' unless @photos.all? { |photo| image?(photo) }

      "Each photo must be under #{MAX_BYTES / 1.megabyte} MB." if @photos.any? { |photo| photo.size > MAX_BYTES }
    end

    def image?(photo)
      photo.respond_to?(:content_type) && photo.content_type.to_s.start_with?('image/')
    end
  end
end
