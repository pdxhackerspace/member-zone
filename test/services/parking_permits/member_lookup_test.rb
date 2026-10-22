require 'test_helper'

module ParkingPermits
  class MemberLookupTest < ActiveSupport::TestCase
    test 'requires an identifier' do
      result = MemberLookup.call

      assert_nil result.user
      assert_equal :bad_request, result.status
    end

    test 'finds a member by slack uid on the user record' do
      user = users(:one)
      user.update_columns(slack_id: 'ULOOKUP1')

      result = MemberLookup.call(slack_uid: 'ULOOKUP1')

      assert_equal user, result.user
      assert_equal :ok, result.status
    end

    test 'finds a member through a linked slack user' do
      user = users(:one)
      slack_user = slack_users(:with_dept)
      slack_user.update!(user: user, slack_id: 'ULINKED1')

      result = MemberLookup.call(slack_uid: 'ULINKED1')

      assert_equal user, result.user
    end

    test 'refuses when more than one member matches slack uid' do
      first = users(:one)
      second = users(:two)
      first.update_columns(slack_id: 'UDUPE')
      second.update_columns(slack_id: 'UDUPE')

      result = MemberLookup.call(slack_uid: 'UDUPE')

      assert_nil result.user
      assert_equal :conflict, result.status
    end
  end
end
