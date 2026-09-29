require 'test_helper'

class AuditLogAlertRuleTest < ActiveSupport::TestCase
  setup { @source = create_audit_log_source }

  def rule(pattern, **attrs)
    @source.audit_log_alert_rules.build({ name: 'rule', pattern: pattern }.merge(attrs))
  end

  test 'requires a name and a pattern' do
    built = @source.audit_log_alert_rules.build
    assert_not built.valid?
    assert built.errors.key?(:name)
    assert built.errors.key?(:pattern)
  end

  test 'rejects a pattern that is not a valid regular expression' do
    built = rule('(unclosed')
    assert_not built.valid?
    assert_match(/not a valid regular expression/, built.errors[:pattern].to_sentence)
  end

  test 'matches ignoring case by default and honours case sensitivity when asked' do
    assert rule('failed login').matches?('FAILED LOGIN for root')
    assert_not rule('failed login', case_insensitive: false).matches?('FAILED LOGIN for root')
    assert rule('FAILED', case_insensitive: false).matches?('FAILED LOGIN')
  end

  test 'supports real regular expression syntax' do
    assert rule('door \d+ (opened|closed)').matches?('door 12 closed')
    assert_not rule('door \d+ (opened|closed)').matches?('door x closed')
  end

  test 'a pattern that backtracks catastrophically is treated as a non-match instead of hanging' do
    evil = rule('(a+)+$')
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_not evil.matches?("#{'a' * 60}!")
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
  end

  test 'changing the pattern rebuilds the compiled expression' do
    built = rule('alpha')
    assert built.matches?('alpha')

    built.pattern = 'beta'
    assert built.matches?('beta')
    assert_not built.matches?('alpha')
  end

  test 'enabled scope excludes disabled rules' do
    on = @source.audit_log_alert_rules.create!(name: 'on', pattern: 'a')
    @source.audit_log_alert_rules.create!(name: 'off', pattern: 'b', enabled: false)

    assert_equal [on], @source.audit_log_alert_rules.enabled.to_a
  end
end
