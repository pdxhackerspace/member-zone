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

  test 'leaves notice photos off the permit or ticket' do
    @notice.photos.attach(io: file_fixture('parking_photo.png').open, filename: 'parking_photo.png',
                          content_type: 'image/png')

    pdf = ParkingNoticePdf.new(@notice).document.render

    assert_not_includes pdf, '/Subtype /Image'
    assert_not_includes pdf, '(Photos)'
  end
end
