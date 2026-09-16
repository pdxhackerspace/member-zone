# frozen_string_literal: true

require 'test_helper'

class MembershipSettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
    @membership_setting = MembershipSetting.instance
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'show displays application review time cap' do
    @membership_setting.update!(application_review_time_cap_days: 15)

    get membership_settings_url

    assert_response :success
    assert_match 'Application review time cap', response.body
    assert_select '.profile-field-label', text: 'Application review time cap'
    assert_select '.profile-field-value strong', text: '15'
  end

  test 'update saves application review time cap' do
    patch membership_settings_url, params: {
      membership_setting: membership_setting_params.merge(application_review_time_cap_days: 10)
    }

    assert_redirected_to membership_settings_url
    assert_equal 10, @membership_setting.reload.application_review_time_cap_days
  end

  test 'update saves slack signup reminder timing fields' do
    patch membership_settings_url, params: {
      membership_setting: membership_setting_params.merge(
        slack_signup_reminder_initial_delay_days: 10,
        slack_signup_reminder_repeat_delay_days: 21,
        slack_signup_reminder_max_account_age_months: 9
      )
    }

    assert_redirected_to membership_settings_url
    @membership_setting.reload
    assert_equal 10, @membership_setting.slack_signup_reminder_initial_delay_days
    assert_equal 21, @membership_setting.slack_signup_reminder_repeat_delay_days
    assert_equal 9, @membership_setting.slack_signup_reminder_max_account_age_months
  end

  test 'update saves the overdue payment reminder grace period' do
    patch membership_settings_url, params: {
      membership_setting: membership_setting_params.merge(payment_overdue_reminder_grace_days: 3)
    }

    assert_redirected_to membership_settings_url
    assert_equal 3, @membership_setting.reload.payment_overdue_reminder_grace_days
  end

  private

  def membership_setting_params
    {
      payment_grace_period_days: @membership_setting.payment_grace_period_days,
      reactivation_grace_period_months: @membership_setting.reactivation_grace_period_months,
      invitation_expiry_hours: @membership_setting.invitation_expiry_hours,
      login_link_expiry_hours: @membership_setting.login_link_expiry_hours,
      admin_login_link_expiry_minutes: @membership_setting.admin_login_link_expiry_minutes,
      application_verification_expiry_hours: @membership_setting.application_verification_expiry_hours,
      manual_payment_due_soon_days: @membership_setting.manual_payment_due_soon_days,
      application_review_time_cap_days: @membership_setting.application_review_time_cap_days,
      slack_signup_reminder_initial_delay_days: @membership_setting.slack_signup_reminder_initial_delay_days,
      slack_signup_reminder_repeat_delay_days: @membership_setting.slack_signup_reminder_repeat_delay_days,
      slack_signup_reminder_max_account_age_months: @membership_setting.slack_signup_reminder_max_account_age_months,
      application_link_reminder_delay_days: @membership_setting.application_link_reminder_delay_days,
      application_link_reminder_max_count: @membership_setting.application_link_reminder_max_count,
      payment_overdue_reminder_grace_days: @membership_setting.payment_overdue_reminder_grace_days
    }
  end

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
