require 'test_helper'

class JournalsHelperTest < ActionView::TestCase
  test 'parking notice entry links to the admin notice page' do
    html = render_change_rows(
      'parking_notice' => {
        'id' => 42,
        'notice_type' => 'permit',
        'location' => 'Lot A — north wall',
        'expires_at' => 'June 01, 2026',
        'description' => 'Trailer restoration'
      }
    )

    assert_includes html, parking_notice_path(42)
    assert_includes html, 'View permit'
    assert_includes html, 'Lot A — north wall'
    assert_includes html, 'Expires June 01, 2026 · Trailer restoration'
  end

  test 'parking ticket entry labels its link as a ticket' do
    html = render_change_rows(
      'parking_notice' => {
        'id' => 7,
        'notice_type' => 'ticket',
        'location' => 'Loading dock',
        'expires_at' => 'June 01, 2026'
      }
    )

    assert_includes html, parking_notice_path(7)
    assert_includes html, 'View ticket'
  end

  test 'parking notice entry without an id renders no link' do
    html = render_change_rows('parking_notice' => { 'notice_type' => 'permit', 'location' => 'Lot A' })

    assert_includes html, 'Lot A'
    assert_not_includes html, 'View permit'
  end
end
