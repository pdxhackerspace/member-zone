module ParkingNotices
  # Marks a notice cleared. ParkingNotice#clearable_by? decides who may: staff, the members on
  # it, and — for a notice flagged as needing staff clearance — only those who can clear those.
  class Clear
    def self.call(...)
      new(...).call
    end

    def initialize(notice:, actor:)
      @notice = notice
      @actor = actor
    end

    def call
      return Result.new(notice: @notice, error: :already_cleared) if @notice.cleared?
      return Result.new(notice: @notice, error: :clearance_required) unless @notice.clearable_by?(@actor)

      @notice.event_actor = @actor
      @notice.clear!(@actor)
      @notice.record_journal_entry!('parking_notice_cleared', actor: @actor)
      Result.new(notice: @notice)
    end
  end
end
