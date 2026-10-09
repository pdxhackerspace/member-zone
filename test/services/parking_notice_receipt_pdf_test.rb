require 'test_helper'

class ParkingNoticeReceiptPdfTest < ActiveSupport::TestCase
  setup do
    @notice = parking_notices(:active_permit)
  end

  test 'full_page layout renders non-empty PDF' do
    pdf = ParkingNoticeReceiptPdf.new(@notice, layout: :full_page)
    assert pdf.render.bytesize.positive?
  end

  test 'full_page layout renders when member has slack handle' do
    @notice.members.first.update!(slack_handle: 'receiptslack')

    pdf = ParkingNoticeReceiptPdf.new(@notice, layout: :full_page)
    assert pdf.render.bytesize.positive?
    member = @notice.members.first
    assert_equal "#{member.username} @receiptslack", member.parking_member_label
  end

  test 'thermal layout renders non-empty PDF' do
    pdf = ParkingNoticeReceiptPdf.new(@notice, layout: :thermal, thermal_width_mm: 88)
    assert pdf.render.bytesize.positive?
  end

  test 'thermal layout requires width' do
    assert_raises(ArgumentError) { ParkingNoticeReceiptPdf.new(@notice, layout: :thermal) }
  end

  test 'rejects unknown layout' do
    assert_raises(ArgumentError) { ParkingNoticeReceiptPdf.new(@notice, layout: :nosuch) }
  end

  test 'mm_to_pt converts 88mm to points' do
    pt = ParkingNoticeReceiptPdf.mm_to_pt(88)
    assert_in_delta 249.45, pt, 0.05
  end
end
