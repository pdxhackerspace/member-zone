module ParkingNotices
  # A member asking staff to clear a notice they cannot clear themselves.
  class RequestClearance
    def self.call(...)
      new(...).call
    end

    def initialize(notice:, actor:)
      @notice = notice
      @actor = actor
    end

    def call
      return Result.new(notice: @notice, error: :not_needed) if @notice.cleared? || !@notice.requires_admin_clearance?
      return Result.new(notice: @notice, error: :already_requested) if @notice.clearance_requested?

      @notice.request_clearance!(@actor)
      Result.new(notice: @notice)
    end
  end
end
