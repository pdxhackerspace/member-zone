require 'test_helper'

class AuditLogAlertMailerTest < ActionMailer::TestCase
  setup do
    EmailTemplate.seed_defaults!
    @source = create_audit_log_source(name: 'Door syslog')
    @entries = [
      create_audit_log_entry(@source, message: 'Failed login for <root>', occurred_at: 2.hours.ago),
      create_audit_log_entry(@source, message: 'Second failure', occurred_at: 1.hour.ago)
    ]
    @recipient = users(:one)
  end

  test 'uses the audit_log_alert template' do
    template = EmailTemplate.find_by!(key: 'audit_log_alert')
    template.update!(subject: 'ALERT {{audit_source_name}} x{{audit_match_count}}')

    mail = MemberMailer.audit_log_alert(@recipient, @source, @entries.map(&:id))

    assert_equal ['user1@example.com'], mail.to
    assert_equal 'ALERT Door syslog x2', mail.subject
  end

  test 'the template lists the entries newest first, escapes them, and links to the log' do
    mail = MemberMailer.audit_log_alert(@recipient, @source, @entries.map(&:id))
    html = mail.html_part&.body.to_s.presence || mail.body.to_s

    assert_includes html, 'Failed login for &lt;root&gt;'
    assert_not_includes html, 'Failed login for <root>'
    assert_operator html.index('Second failure'), :<, html.index('Failed login')
    assert_includes html, "/audit_log_entries?source=#{@source.id}"
    assert_includes mail.text_part.body.to_s, 'Second failure'
  end

  test 'falls back to the built-in views when the template is disabled' do
    EmailTemplate.where(key: 'audit_log_alert').update_all(enabled: false)

    mail = MemberMailer.audit_log_alert(@recipient, @source, @entries.map(&:id))

    assert_includes mail.subject, '2 audit log alert(s) from Door syslog'
    assert_includes mail.text_part.body.to_s, 'Failed login for <root>'
    assert_includes mail.html_part.body.to_s, 'Second failure'
    assert_includes mail.text_part.body.to_s, "/audit_log_entries?source=#{@source.id}"
  end

  test 'only the named entries of this source are listed' do
    other = create_audit_log_source
    stranger = create_audit_log_entry(other, message: 'from another source')

    mail = MemberMailer.audit_log_alert(@recipient, @source, [@entries.first.id, stranger.id])

    body = mail.text_part&.body.to_s.presence || mail.body.to_s
    assert_includes body, 'Failed login'
    assert_not_includes body, 'from another source'
  end

  test 'the email carries the opt-out footer' do
    mail = MemberMailer.audit_log_alert(@recipient, @source, @entries.map(&:id))

    assert_match(/turn them off/i, mail.text_part&.body.to_s.presence || mail.body.to_s)
  end

  test 'the default template documents its variables in the editor' do
    variables = EmailTemplate.editor_variables_for('audit_log_alert')

    assert_includes variables, '{{audit_source_name}}'
    assert_includes variables, '{{audit_matches_html}}'
    assert_includes variables, '{{audit_log_url}}'
  end
end
