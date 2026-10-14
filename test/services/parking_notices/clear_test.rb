require 'test_helper'

module ParkingNotices
  class ClearTest < ActiveSupport::TestCase
    test 'a member on the notice may clear it' do
      notice = parking_notices(:active_permit)
      result = Clear.call(notice: notice, actor: users(:one))

      assert result.success?
      assert notice.reload.cleared?
      assert_equal users(:one), notice.cleared_by
      assert Journal.exists?(action: 'parking_notice_cleared', user: users(:one))
    end

    test 'an already cleared notice is refused' do
      result = Clear.call(notice: parking_notices(:cleared_permit), actor: users(:one))

      assert_equal :already_cleared, result.error
    end

    test 'someone not on the notice without the privilege is refused' do
      notice = parking_notices(:active_permit)
      result = Clear.call(notice: notice, actor: users(:two))

      assert_equal :clearance_required, result.error
      assert_not notice.reload.cleared?
    end

    test 'a notice needing staff clearance is refused to its own member' do
      notice = parking_notices(:active_permit)
      notice.update!(requires_admin_clearance: true)

      assert_equal :clearance_required, Clear.call(notice: notice, actor: users(:one)).error
    end

    test 'staff with the clearance privilege may clear a flagged notice' do
      notice = parking_notices(:active_permit)
      notice.update!(requires_admin_clearance: true)
      staff = users(:two)
      grant_privileges(staff, 'parking.clear_admin_required')

      assert Clear.call(notice: notice, actor: staff).success?
    end
  end
end
