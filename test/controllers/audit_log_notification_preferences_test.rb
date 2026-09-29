require 'test_helper'

class AuditLogNotificationPreferencesTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'a plain member does not see the audit log alerts row' do
    sign_in_as_plain_member

    get notification_preferences_path
    assert_response :success
    assert_select 'td', text: /Audit log alerts/, count: 0
  end

  test 'an alert recipient sees the row and can turn it off and on' do
    member = sign_in_as_plain_member
    grant_privileges(member, 'audit_logs.alerts_all')
    sign_in_as_plain_member

    get notification_preferences_path
    assert_select 'td', text: /Audit log alerts/

    patch notification_preferences_path, params: { preferences: { 'audit_log_alerts' => { 'email' => '0' } } }
    assert NotificationOptOut.opted_out?(member, category: 'audit_log_alerts')

    patch notification_preferences_path, params: { preferences: { 'audit_log_alerts' => { 'email' => '1' } } }
    assert_not NotificationOptOut.opted_out?(member, category: 'audit_log_alerts')
  end
end
