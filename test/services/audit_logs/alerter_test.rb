require 'test_helper'

module AuditLogs
  class AlerterTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @source = create_audit_log_source
      @admin = users(:one)
      @admin.update_columns(is_admin: true)
      @failed = create_audit_log_entry(@source, message: 'Failed login for root')
      @quiet = create_audit_log_entry(@source, message: 'Session opened')
      @rule = @source.audit_log_alert_rules.create!(name: 'Failed logins', pattern: 'failed login')
      ActionMailer::Base.deliveries.clear
    end

    test 'stamps matching entries with the rules that matched and when' do
      matched = nil
      perform_enqueued_jobs { matched = Alerter.call(@source, [@failed, @quiet]) }

      assert_equal [@failed], matched
      assert_equal [@rule.id], @failed.reload.matched_rule_ids
      assert_predicate @failed, :alerted?
      assert_not_predicate @quiet.reload, :alerted?
      assert_empty @quiet.matched_rule_ids
    end

    test 'sends each recipient one email for the whole run' do
      second = create_audit_log_entry(@source, message: 'FAILED LOGIN again')
      other = users(:two)
      grant_privileges(other, 'audit_logs.alerts_all')

      perform_enqueued_jobs { Alerter.call(@source, [@failed, second, @quiet]) }

      mails = ActionMailer::Base.deliveries
      assert_equal [@admin.email, other.email].sort, mails.flat_map(&:to).sort
      mail = mails.find { |m| m.to == [@admin.email] }
      assert_includes mail.subject, '2 audit log alert'
      assert_includes mail.subject, @source.name
      assert_includes mail.body.encoded, 'Failed login for root'
      assert_includes mail.body.encoded, 'FAILED LOGIN again'
      assert_not_includes mail.body.encoded, 'Session opened'
    end

    test 'nothing is sent when nothing matches' do
      assert_no_enqueued_jobs { Alerter.call(@source, [@quiet]) }
      assert_not_predicate @quiet.reload, :alerted?
    end

    test 'disabled rules do not alert' do
      @rule.update!(enabled: false)

      assert_no_enqueued_jobs { assert_empty Alerter.call(@source, [@failed]) }
      assert_not_predicate @failed.reload, :alerted?
    end

    test 'a source with no rules never alerts' do
      other = create_audit_log_source
      entry = create_audit_log_entry(other, message: 'Failed login')

      assert_no_enqueued_jobs { assert_empty Alerter.call(other, [entry]) }
    end

    test 'rules belonging to another source are ignored' do
      other = create_audit_log_source
      entry = create_audit_log_entry(other, message: 'Failed login')

      assert_empty Alerter.call(other, [entry])
    end

    test 'records every rule that matched an entry' do
      broad = @source.audit_log_alert_rules.create!(name: 'root', pattern: 'root')

      Alerter.call(@source, [@failed])

      assert_equal [@rule.id, broad.id].sort, @failed.reload.matched_rule_ids.sort
    end

    test 'a rule that times out does not stop the others' do
      slow = @source.audit_log_alert_rules.create!(name: 'slow', pattern: '(a+)+$')
      slow_entry = create_audit_log_entry(@source, message: "#{'a' * 60}!")

      matched = Alerter.call(@source, [slow_entry, @failed])

      assert_equal [@failed], matched
      assert_empty slow_entry.reload.matched_rule_ids
      assert_predicate slow, :persisted?
    end

    test 'a recipient who opted out of audit log alerts is not emailed' do
      NotificationOptOut.opt_out!(@admin, category: 'audit_log_alerts')

      perform_enqueued_jobs { Alerter.call(@source, [@failed]) }

      assert_empty ActionMailer::Base.deliveries
      assert_predicate @failed.reload, :alerted?, 'the match is still recorded'
    end

    test 'the email lists at most 50 entries but reports the full count' do
      entries = Array.new(55) { |i| create_audit_log_entry(@source, message: "Failed login #{i}") }

      perform_enqueued_jobs { Alerter.call(@source, entries) }

      mail = ActionMailer::Base.deliveries.sole
      assert_includes mail.subject, '55 audit log alert'
      assert_equal 50, mail.text_part.body.to_s.scan('Failed login ').size
    end

    # --- Retry ---

    def failing_mailer
      original = MemberMailer.method(:audit_log_alert)
      MemberMailer.define_singleton_method(:audit_log_alert) { |*| raise 'queue is down' }
      yield
    ensure
      MemberMailer.define_singleton_method(:audit_log_alert, original)
    end

    test 'every entry offered is marked checked once handed off, matched or not' do
      perform_enqueued_jobs { Alerter.call(@source, [@failed, @quiet]) }

      assert_not_nil @failed.reload.alert_checked_at
      assert_not_nil @quiet.reload.alert_checked_at
    end

    test 'if sending fails nothing is stamped, so the entries are offered again' do
      failing_mailer do
        assert_raises(RuntimeError) { Alerter.call(@source, [@failed, @quiet]) }
      end

      assert_nil @failed.reload.alert_checked_at
      assert_nil @failed.alerted_at
      assert_empty @failed.matched_rule_ids
      assert_nil @quiet.reload.alert_checked_at

      perform_enqueued_jobs { Alerter.call(@source, [@failed, @quiet]) }
      assert_equal 1, ActionMailer::Base.deliveries.size
      assert_predicate @failed.reload, :alerted?
    end

    test 'nothing offered means nothing sent' do
      assert_no_enqueued_jobs { assert_empty Alerter.call(@source, []) }
    end
  end
end
