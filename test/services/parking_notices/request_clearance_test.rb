require 'test_helper'

module ParkingNotices
  class RequestClearanceTest < ActiveSupport::TestCase
    setup do
      @notice = parking_notices(:active_permit)
      @member = users(:one)
    end

    test 'records the request on a notice that needs staff clearance' do
      @notice.update!(requires_admin_clearance: true)
      result = RequestClearance.call(notice: @notice, actor: @member)

      assert result.success?
      assert @notice.reload.clearance_requested?
      assert_equal @member, @notice.clearance_requested_by
    end

    test 'is not needed when the member can clear it themselves' do
      assert_equal :not_needed, RequestClearance.call(notice: @notice, actor: @member).error
    end

    test 'is not needed once cleared' do
      notice = parking_notices(:cleared_permit)
      notice.update_columns(requires_admin_clearance: true)

      assert_equal :not_needed, RequestClearance.call(notice: notice, actor: @member).error
    end

    test 'is refused a second time' do
      @notice.update!(requires_admin_clearance: true)
      RequestClearance.call(notice: @notice, actor: @member)

      assert_equal :already_requested, RequestClearance.call(notice: @notice, actor: @member).error
    end
  end
end
