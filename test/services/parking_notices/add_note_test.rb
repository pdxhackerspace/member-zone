require 'test_helper'

module ParkingNotices
  class AddNoteTest < ActiveSupport::TestCase
    test 'adds a stripped note to the history' do
      notice = parking_notices(:active_permit)
      result = AddNote.call(notice: notice, actor: users(:one), note: "  Moved to bench B \n")

      assert result.success?
      event = notice.events.where(event_type: 'note').last
      assert_equal 'Moved to bench B', event.note
      assert_equal users(:one), event.actor
    end

    test 'refuses a blank note' do
      notice = parking_notices(:active_permit)

      assert_no_difference -> { notice.events.count } do
        assert_equal :blank_note, AddNote.call(notice: notice, actor: users(:one), note: '   ').error
      end
    end
  end
end
