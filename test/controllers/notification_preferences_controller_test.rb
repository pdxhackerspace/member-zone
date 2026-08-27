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
      assert_response :success
      assert_match 'Notifications', response.body
      assert_match 'Overdue payment reminders', response.body
      assert_match 'Parking permit and ticket reminders', response.body
    end
  end

  test 'GET with token does not opt out member' do
    token = @member.generate_token_for(:notification_preferences)
    assert_no_difference 'NotificationOptOut.count' do
      get token_notification_preferences_path(token: token, highlight: 'payment_overdue')
      assert_response :success
    end
    assert_match 'Turn off email for this notice', response.body
  end

  test 'POST opt_out creates opt-out and redirects' do
    with_local_auth do
      sign_in_as_plain_member
      assert_difference 'NotificationOptOut.count', 1 do
        post notification_preferences_opt_out_path,
             params: { category: 'payment_overdue', channel: 'email' }
      end
      assert_redirected_to notification_preferences_path
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
      assert_redirected_to notification_preferences_path
      assert NotificationOptOut.opted_out?(@member, category: 'payment_overdue', channel: 'email')
      assert_not NotificationOptOut.opted_out?(@member, category: 'payment_overdue', channel: 'slack')
    end
  end
end
