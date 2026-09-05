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
    assert_match 'Orientation reminder', response.body
    assert_select 'input[type=submit][value=Save]', count: 0
    assert_select 'form[data-controller=?]', 'reminder-setting-form'
    assert_select 'button', text: 'Send now', minimum: 6
  end

  test 'index lists lapsed access reminder with preview counts' do
    get reminder_settings_url

    assert_response :success
    assert_match 'Lapsed member access reminder', response.body
    assert_match 'badged in during the window', response.body
  end

  test 'index offers a lookback window field only for reminders that scan a range' do
    ReminderSetting.find_by!(key: 'lapsed_access').update!(lookback_days: 4)

    get reminder_settings_url

    assert_response :success
    assert_select 'input#reminder_lookback_days_lapsed_access[value=?]', '4'
    assert_select 'input#reminder_lookback_days_payment_overdue', count: 0
    assert_match 'daily scan of the last 4 days of access logs', response.body
  end

  test 'update changes the lapsed access lookback window' do
    reminder = ReminderSetting.find_by!(key: 'lapsed_access')

    patch reminder_setting_url('lapsed_access'), params: { reminder_setting: { lookback_days: '14' } }

    assert_redirected_to reminder_settings_url
    assert_equal 14, reminder.reload.lookback_days
  end

  test 'update rejects an out-of-range lookback window' do
    reminder = ReminderSetting.find_by!(key: 'lapsed_access')
    reminder.update!(lookback_days: 3)

    patch reminder_setting_url('lapsed_access'), params: { reminder_setting: { lookback_days: '0' } }

    assert_redirected_to reminder_settings_url
    assert_match(/not updated/i, flash[:alert])
    assert_equal 3, reminder.reload.lookback_days
  end

  test 'update ignores a lookback window on reminders that do not scan a range' do
    patch reminder_setting_url('payment_overdue'), params: {
      reminder_setting: { enabled: '1', lookback_days: '30' }
    }

    assert_redirected_to reminder_settings_url
    assert_equal 1, ReminderSetting.find_by!(key: 'payment_overdue').lookback_days
  end

  test 'show lists due inactive members for lapsed access' do
    now = Time.zone.local(2026, 8, 6, 8, 5, 0)
    user = User.create!(
      email: 'due-lapsed-access@example.com',
      full_name: 'Due Lapsed Access User',
      service_account: false,
      membership_state: 'inactive_member',
      payment_type: 'unknown',
      last_payment_date: (now - 30.days).to_date
    )
    user.update_columns(membership_state_entered_at: now - 45.days)
    AccessLog.create!(user: user, logged_at: now - 1.hour, name: user.display_name, action: 'opened')

    travel_to now do
      get reminder_setting_url('lapsed_access')
    end

    assert_response :success
    assert_match user.display_name, response.body
  end

  test 'show counts the new visits behind each due member' do
    now = Time.zone.local(2026, 8, 6, 8, 5, 0)
    user = User.create!(
      email: 'repeat-visitor@example.com',
      full_name: 'Repeat Visitor',
      service_account: false,
      membership_state: 'inactive_member',
      payment_type: 'unknown',
      last_payment_date: (now - 30.days).to_date
    )
    user.update_columns(membership_state_entered_at: now - 45.days)
    3.times { |i| AccessLog.create!(user: user, logged_at: now - (i + 1).hours, name: user.display_name) }

    travel_to now do
      get reminder_setting_url('lapsed_access')
    end

    assert_response :success
    assert_select 'th', text: 'New visits'
    assert_select 'td.num', text: '3'
  end

  test 'show lists members waiting on their orientation' do
    now = Time.zone.local(2026, 8, 5, 7, 45, 0)
    MembershipSetting.instance.update!(
      orientation_reminder_repeat_days: 14,
      new_member_expiry_days: 90,
      building_access_training_topic: training_topics(:building_access)
    )
    user = User.create!(
      email: 'awaiting-orientation-preview@example.com',
      full_name: 'Awaiting Orientation User',
      service_account: false,
      membership_state: 'new_member',
      payment_type: 'unknown'
    )
    user.update_columns(membership_state_entered_at: now - 20.days)
    MembershipApplication.create!(
      user: user,
      email: user.email,
      status: 'approved',
      reviewed_at: now - 20.days,
      submitted_at: now - 22.days
    )

    travel_to now do
      get reminder_setting_url('orientation')
    end

    assert_response :success
    assert_match 'Awaiting Orientation User', response.body
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

  test 'index preserves admin allow_opt_out changes' do
    reminder = ReminderSetting.find_by!(key: 'payment_overdue')
    reminder.update!(allow_opt_out: false)

    get reminder_settings_url

    assert_response :success
    assert_not reminder.reload.allow_opt_out?
  end

  test 'send now runs slack signup reminder when enabled' do
    reminder = ReminderSetting.find_by!(key: 'slack_signup')
    reminder.update!(enabled: true)
    MemberSource.find_or_create_by!(key: 'slack') { |source| source.enabled = true }
    MemberSource.find_by!(key: 'slack').update!(enabled: true)

    post send_now_reminder_setting_url('slack_signup')

    assert_redirected_to reminder_settings_url
    assert_match(/run finished/i, flash[:notice])
  end

  test 'send now blocked when reminder disabled' do
    ReminderSetting.find_by!(key: 'slack_signup').update!(enabled: false)

    post send_now_reminder_setting_url('slack_signup')

    assert_redirected_to reminder_settings_url
    assert_match(/disabled/i, flash[:alert])
  end

  private

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
