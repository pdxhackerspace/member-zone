require 'test_helper'

class AuditLogAlertRulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @source = create_audit_log_source
    @rule = @source.audit_log_alert_rules.create!(name: 'Failed logins', pattern: 'failed login')
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  def sign_in_manager
    member = sign_in_as_plain_member
    grant_privileges(member, 'audit_logs.manage')
    sign_in_as_plain_member
  end

  test 'a plain member cannot add, change or remove rules' do
    sign_in_as_plain_member

    post audit_log_source_audit_log_alert_rules_path(@source),
         params: { audit_log_alert_rule: { name: 'x', pattern: 'y' } }
    patch audit_log_source_audit_log_alert_rule_path(@source, @rule),
          params: { audit_log_alert_rule: { pattern: 'changed' } }
    delete audit_log_source_audit_log_alert_rule_path(@source, @rule)

    assert_equal 1, @source.audit_log_alert_rules.count
    assert_equal 'failed login', @rule.reload.pattern
  end

  test 'a reader without manage cannot add rules' do
    member = sign_in_as_plain_member
    grant_privileges(member, 'audit_logs.view_all', 'audit_logs.alerts_all')
    sign_in_as_plain_member

    post audit_log_source_audit_log_alert_rules_path(@source),
         params: { audit_log_alert_rule: { name: 'x', pattern: 'y' } }
    assert_equal 1, @source.audit_log_alert_rules.count
  end

  test 'a manager adds a rule' do
    sign_in_manager

    assert_difference -> { @source.audit_log_alert_rules.count }, 1 do
      post audit_log_source_audit_log_alert_rules_path(@source),
           params: { audit_log_alert_rule: { name: 'Sudo', pattern: 'sudo:.*FAILED', case_insensitive: '0' } }
    end

    assert_redirected_to audit_log_source_path(@source)
    rule = @source.audit_log_alert_rules.find_by!(name: 'Sudo')
    assert_not rule.case_insensitive?
    assert_predicate rule, :enabled?
  end

  test 'an invalid pattern is refused with the reason' do
    sign_in_manager

    assert_no_difference -> { AuditLogAlertRule.count } do
      post audit_log_source_audit_log_alert_rules_path(@source),
           params: { audit_log_alert_rule: { name: 'Broken', pattern: '(oops' } }
    end
    assert_redirected_to audit_log_source_path(@source)
    assert_match(/not a valid regular expression/, flash[:alert])
  end

  test 'a manager disables and re-enables a rule' do
    sign_in_manager

    rule_path = audit_log_source_audit_log_alert_rule_path(@source, @rule)
    patch rule_path, params: { audit_log_alert_rule: { enabled: 'false' } }
    assert_not_predicate @rule.reload, :enabled?

    patch rule_path, params: { audit_log_alert_rule: { enabled: 'true' } }
    assert_predicate @rule.reload, :enabled?
  end

  test 'a manager removes a rule and entries that matched it are unaffected' do
    entry = create_audit_log_entry(@source, matched_rule_ids: [@rule.id], alerted_at: Time.current)
    sign_in_manager

    assert_difference -> { AuditLogAlertRule.count }, -1 do
      delete audit_log_source_audit_log_alert_rule_path(@source, @rule)
    end
    assert_predicate entry.reload, :alerted?
  end

  test 'a rule cannot be reached through another source' do
    other = create_audit_log_source
    sign_in_manager

    patch audit_log_source_audit_log_alert_rule_path(other, @rule),
          params: { audit_log_alert_rule: { pattern: 'hijack' } }
    assert_response :not_found
    assert_equal 'failed login', @rule.reload.pattern
  end
end
