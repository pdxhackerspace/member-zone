require 'test_helper'

class ParkingClearancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @notice = parking_notices(:active_permit)
    @membership = @notice.parking_notice_members.find_by!(user: users(:one))
    @token = @membership.generate_token_for(:arrival_clearance)
  end

  test 'opening the link shows the notice and does not clear it' do
    get parking_clearance_path(@token)

    assert_response :success
    assert_match 'Clear this permit', response.body
    assert_match @notice.description, response.body
    assert_not @notice.reload.cleared?
  end

  test 'the button clears the notice' do
    post parking_clearance_path(@token)

    assert_redirected_to parking_clearance_path(@token)
    assert @notice.reload.cleared?
    assert_equal users(:one), @notice.cleared_by

    follow_redirect!
    assert_match 'already cleared', response.body
  end

  test 'a notice that needs staff clearance requests it instead of clearing' do
    @notice.update!(requires_admin_clearance: true)

    get parking_clearance_path(@token)

    assert_response :success
    assert_match 'Request clearance', response.body
    assert_no_match(/Clear this permit/, response.body)

    post parking_clearance_path(@token)

    assert @notice.reload.clearance_requested?
    assert_not @notice.cleared?
  end

  test 'an unknown token and an expired token show the same page' do
    get parking_clearance_path('not-a-token')

    assert_response :not_found
    assert_match 'no longer works', response.body

    travel 8.days do
      get parking_clearance_path(@token)
    end

    assert_response :not_found
    assert_match 'no longer works', response.body
  end
end
