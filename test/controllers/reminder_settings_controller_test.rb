require 'test_helper'

class ReminderSettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
    ReminderSetting.seed_defaults!
    MembershipSetting.instance.update!(
      slack_signup_reminder_initial_delay_days: 7,
      slack_signup_reminder_repeat_delay_days: 14,
      application_link_reminder_delay_days: 3,
      application_link_reminder_max_count: 3,
      use_builtin_membership_application: true
    )
    ReminderSetting.find_by!(key: 'application_link').update!(enabled: true)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'index lists slack signup reminder with preview counts' do
    get reminder_settings_url

    assert_response :success
    assert_match 'Slack signup reminder', response.body
    assert_match 'would be emailed today', response.body
    assert_match 'Application link reminder', response.body
  end

  test 'show lists due members for slack signup' do
    now = Time.zone.local(2026, 8, 5, 7, 0, 0)
    user = User.create!(
      email: 'due-preview@example.com',
      full_name: 'Due Preview User',
      active: true,
      service_account: false,
      membership_state: 'current_member',
      payment_type: 'unknown'
    )
    MembershipApplication.create!(
      user: user,
      email: user.email,
      status: 'approved',
      reviewed_at: now - 10.days,
      submitted_at: now - 12.days
    )

    travel_to now do
      get reminder_setting_url('slack_signup')
    end

    assert_response :success
    assert_match 'Due Preview User', response.body
  end

  test 'show lists due verifications for application link' do
    now = Time.zone.local(2026, 8, 5, 7, 15, 0)
    verification = ApplicationVerification.create!(
      email: 'awaiting-application@example.com',
      confirmed_open_house: true,
      confirmed_code_of_conduct: true,
      created_at: now - 4.days,
      expires_at: now + 2.days
    )

    travel_to now do
      get reminder_setting_url('application_link')
    end

    assert_response :success
    assert_match verification.email, response.body
  end

  test 'show hides due verifications when application link reminder is disabled' do
    now = Time.zone.local(2026, 8, 5, 7, 15, 0)
    ReminderSetting.find_by!(key: 'application_link').update!(enabled: false)
    verification = ApplicationVerification.create!(
      email: 'disabled-show@example.com',
      confirmed_open_house: true,
      confirmed_code_of_conduct: true,
      created_at: now - 4.days,
      expires_at: now + 2.days
    )

    travel_to now do
      get reminder_setting_url('application_link')
    end

    assert_response :success
    assert_no_match verification.email, response.body
  end

  test 'show hides due verifications when builtin application is disabled' do
    now = Time.zone.local(2026, 8, 5, 7, 15, 0)
    MembershipSetting.instance.update!(use_builtin_membership_application: false)
    verification = ApplicationVerification.create!(
      email: 'builtin-off-show@example.com',
      confirmed_open_house: true,
      confirmed_code_of_conduct: true,
      created_at: now - 4.days,
      expires_at: now + 2.days
    )

    travel_to now do
      get reminder_setting_url('application_link')
    end

    assert_response :success
    assert_no_match verification.email, response.body
  end

  test 'update toggles reminder enabled state' do
    reminder = ReminderSetting.find_by!(key: 'slack_signup')
    reminder.update!(enabled: false)

    patch reminder_setting_url('slack_signup'), params: { reminder_setting: { enabled: '1' } }

    assert_redirected_to reminder_settings_url
    assert reminder.reload.enabled?
  end

  private

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
