module ParkingNotices
  # Adds a note to a notice's history.
  class AddNote
    def self.call(...)
      new(...).call
    end

    def initialize(notice:, actor:, note:)
      @notice = notice
      @actor = actor
      @note = note.to_s.strip
    end

    def call
      return Result.new(notice: @notice, error: :blank_note) if @note.blank?

      @notice.log_event!('note', actor: @actor, note: @note)
      @notice.record_journal_entry!('parking_notice_note_added', actor: @actor, note: @note)
      Result.new(notice: @notice)
    end
  end
end
