require 'test_helper'

class NotificationPreferencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @member = users(:member_with_local_account)
    ReminderSetting.seed_defaults!
  end

  test 'member can view notification preferences when signed in' do
    with_local_auth do
      sign_in_as_plain_member
      get notification_preferences_path
      assert_redirected_to user_path(@member, tab: :notifications, view_as: :self)
      follow_redirect!
      assert_response :success
      assert_select 'a.nav-link.active', text: 'Notifications'
      assert_select 'a.nav-link', text: 'Profile'
      assert_select 'a', text: 'Back to your profile', count: 0
      assert_match 'Notifications', response.body
      assert_match 'Overdue dues and lapse notices', response.body
      assert_match 'Parking permit and ticket reminders', response.body
    end
  end

  test 'saving from an admin own profile keeps the profile tabs' do
    with_local_auth do
      sign_in_as_admin
      admin = User.by_email(local_accounts(:active_admin).email).first!
      patch notification_preferences_path, params: {
        return_to: 'profile', preferences: { 'orientation' => { 'email' => '0' } }
      }
      assert_redirected_to user_path(admin, tab: :notifications, view_as: :self)
      follow_redirect!
      assert_response :success
      assert_select 'a.nav-link.active', text: 'Notifications'
      assert_select 'a.nav-link[href=?]', user_path(admin, tab: :profile, view_as: :self), text: 'Profile'
      assert_select '#pref_orientation_email[checked]', count: 0
    end
  end

  test 'GET with token does not opt out member' do
    token = @member.generate_token_for(:notification_preferences)
    assert_no_difference 'NotificationOptOut.count' do
      get token_notification_preferences_path(token: token, highlight: 'payment_overdue')
      assert_response :success
    end
    assert_match 'Turn off email for this notice', response.body
    assert_match 'Signed in via email link', response.body
  end

  test 'POST opt_out creates opt-out and redirects' do
    with_local_auth do
      sign_in_as_plain_member
      assert_difference 'NotificationOptOut.count', 1 do
        post notification_preferences_opt_out_path,
             params: { category: 'payment_overdue', channel: 'email' }
      end
      assert_redirected_to user_path(@member, tab: :notifications, view_as: :self)
      follow_redirect!
      assert_response :success
    end
  end

  test 'token opt_out works without session' do
    token = @member.generate_token_for(:notification_preferences)
    assert_difference 'NotificationOptOut.count', 1 do
      post token_notification_preferences_opt_out_path(token: token),
           params: { category: 'orientation', channel: 'email' }
    end
    assert_redirected_to token_notification_preferences_path(token: token)
  end

  test 'token link applies to token owner when another user is signed in' do
    token = @member.generate_token_for(:notification_preferences)

    with_local_auth do
      sign_in_as_admin
      assert_difference -> { NotificationOptOut.where(user: @member).count }, 1 do
        post token_notification_preferences_opt_out_path(token: token),
             params: { category: 'payment_overdue', channel: 'email' }
      end
    end

    assert NotificationOptOut.opted_out?(@member, category: 'payment_overdue', channel: 'email')
    admin = User.by_email(local_accounts(:active_admin).email)
    assert_not NotificationOptOut.opted_out?(admin, category: 'payment_overdue', channel: 'email')
  end

  test 'invalid token redirects to login' do
    get token_notification_preferences_path(token: 'invalid-token')
    assert_redirected_to login_path
  end

  test 'patch update toggles preferences' do
    with_local_auth do
      sign_in_as_plain_member
      patch notification_preferences_path,
            params: {
              preferences: {
                'payment_overdue' => { 'email' => '0', 'slack' => '1' }
              }
            }
      assert_redirected_to user_path(@member, tab: :notifications, view_as: :self)
      follow_redirect!
      assert_response :success
      assert_select 'a.nav-link.active', text: 'Notifications'
      assert NotificationOptOut.opted_out?(@member, category: 'payment_overdue', channel: 'email')
      assert_not NotificationOptOut.opted_out?(@member, category: 'payment_overdue', channel: 'slack')
    end
  end
end
