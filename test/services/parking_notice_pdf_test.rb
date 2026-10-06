require 'test_helper'

class ParkingNoticePdfTest < ActiveSupport::TestCase
  setup do
    @notice = parking_notices(:active_permit)
  end

  test 'renders non-empty PDF' do
    pdf = ParkingNoticePdf.new(@notice)
    assert pdf.document.render.bytesize.positive?
  end

  test 'renders PDF when member has slack handle' do
    @notice.members.first.update!(slack_handle: 'permitslack')

    pdf = ParkingNoticePdf.new(@notice)
    assert pdf.document.render.bytesize.positive?
    member = @notice.members.first
    assert_equal "#{member.username} @permitslack", member.parking_member_label
  end
end
