require 'test_helper'

module ParkingNotices
  class MemberResolutionTest < ActiveSupport::TestCase
    test 'normalize drops blanks and duplicates' do
      assert_equal [3, 4], MemberResolution.normalize(['3', '', nil, 4, '3'])
      assert_equal [], MemberResolution.normalize(nil)
    end

    test 'self service always includes the viewer' do
      viewer = users(:two)

      assert_equal [viewer.id], MemberResolution.for_self_service([], viewer)
    end

    test 'self service adds members whose profiles the viewer can see' do
      viewer = users(:two)
      ids = MemberResolution.for_self_service([users(:three).id], viewer)

      assert_equal [users(:three).id, viewer.id].sort, ids.sort
    end

    test 'self service skips members the viewer cannot pick' do
      viewer = users(:two)
      users(:three).update_columns(profile_visibility: 'private')

      assert_equal [viewer.id], MemberResolution.for_self_service([users(:three).id], viewer)
    end

    test 'pickable_for leaves out the viewer and service accounts' do
      viewer = users(:two)
      users(:three).update_columns(service_account: true)
      pickable = MemberResolution.pickable_for(viewer)

      assert_not_includes pickable, viewer
      assert_not_includes pickable, users(:three)
    end
  end
end
