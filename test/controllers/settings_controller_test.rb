require 'test_helper'

class SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'should get index' do
    get settings_url
    assert_response :success
  end

  test 'settings index loads after nag settings table rename' do
    get settings_url

    assert_response :success
    assert_select 'a[href=?]', reminder_settings_path
  end

  test 'settings index links map defaults separately from application group defaults' do
    get settings_url

    assert_response :success
    assert_select 'a[href=?]', default_settings_path, text: /Application group defaults/
    assert_select 'a[href=?]', map_default_settings_path, text: /Map defaults/
  end

  test 'reminders attention count is zero when slack source is disabled' do
    now = Time.zone.local(2026, 8, 5, 7, 0, 0)
    ReminderSetting.seed_defaults!
    ReminderSetting.find_by!(key: 'slack_signup').update!(enabled: true)
    member_sources(:slack).update!(enabled: false)

    user = User.create!(
      email: 'settings-reminder-attention@example.com',
      full_name: 'Settings Reminder Attention',
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
      get settings_url
    end

    assert_response :success
    assert_select 'a[href=?]', reminder_settings_path do
      assert_select '.badge.text-bg-warning-subtle', count: 0
    end
  end

  test 'application link reminder attention count is zero when builtin apply is disabled' do
    now = Time.zone.local(2026, 8, 6, 7, 15, 0)
    ReminderSetting.seed_defaults!
    ReminderSetting.find_by!(key: 'application_link').update!(enabled: true)
    MembershipSetting.instance.update!(use_builtin_membership_application: false)
    ApplicationVerification.create!(
      email: 'settings-link-due@example.com',
      confirmed_open_house: true,
      confirmed_code_of_conduct: true,
      created_at: now - 4.days,
      expires_at: now + 2.days
    )

    travel_to now do
      get settings_url
    end

    assert_response :success
    assert_select 'a[href=?]', reminder_settings_path do
      assert_select '.badge.text-bg-warning-subtle', count: 0
    end
  end

  private

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
