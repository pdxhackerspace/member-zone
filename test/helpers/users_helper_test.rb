require 'test_helper'

class UsersHelperTest < ActionView::TestCase
  include UsersHelper

  test 'user_live_search_text includes display name email username and authentik id' do
    user = users(:one)
    text = user_live_search_text(user)

    assert_includes text, user.display_name.downcase
    assert_includes text, user.email.downcase
    assert_includes text, user.username.downcase
    assert_includes text, user.authentik_id.downcase
  end

  test 'user_live_search_text omits blank fields' do
    user = users(:no_email)
    text = user_live_search_text(user)

    assert_includes text, user.display_name.downcase
    assert_no_match(/\s{2,}/, text)
  end

  test 'membership_status_label humanizes other statuses' do
    assert_equal 'Paying', membership_status_label('paying')
    assert_equal 'Cancelled', membership_status_label('cancelled')
    assert_equal 'Unknown', membership_status_label('unknown')
  end

  test 'membership_status_label handles a blank status' do
    assert_equal '', membership_status_label(nil)
  end
end
