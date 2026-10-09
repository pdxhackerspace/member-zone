require 'test_helper'

class CredentialMailersTest < ActionMailer::TestCase
  KEYS = %w[credential_expiring_soon credential_expired credentials_revoked].freeze
  SECRET = 'abcd-secret-value-wxyz'.freeze

  setup do
    EmailTemplate.seed_defaults!
    @member = users(:one)
    @opts = { credential_name: 'Fixture OAuth client - laptop', credential_expires_at: 'November 3, 2026',
              credential_names: ['Fixture OAuth client - laptop', 'API key <b>x</b>'],
              credential_reason: 'your membership is no longer active' }
  end

  def deliver(action)
    MemberMailer.public_send(action, @member, @opts.slice(*opts_for(action)))
  end

  def opts_for(action)
    action == :credentials_revoked ? %i[credential_names credential_reason] : %i[credential_name credential_expires_at]
  end

  def html_of(mail)
    mail.html_part&.body.to_s.presence || mail.body.to_s
  end

  test 'the three templates are seeded, enabled and named' do
    KEYS.each do |key|
      template = EmailTemplate.find_by(key: key)
      assert template, "#{key} must be seeded"
      assert template.enabled?
      assert EmailTemplate::DEFAULT_TEMPLATES.key?(key)
    end
  end

  test 'every variable the templates use is documented, sampled and offered in the editor' do
    KEYS.each do |key|
      attrs = EmailTemplate::DEFAULT_TEMPLATES.fetch(key)
      tokens = attrs.values_at(:subject, :body_html, :body_text).join("\n").scan(/\{\{([^}]+)\}\}/).flatten.uniq
      tokens.each do |token|
        assert EmailTemplate::AVAILABLE_VARIABLES.key?("{{#{token}}}"), "#{key}: {{#{token}}} is undocumented"
        assert EmailTemplate::PreviewVariables.all.key?(token.to_sym), "#{key}: {{#{token}}} has no sample"
        assert EmailTemplate.editor_variables_for(key).key?("{{#{token}}}"), "#{key}: {{#{token}}} not in the editor"
      end
    end
  end

  test 'the templates preview without leftover tokens' do
    KEYS.each do |key|
      rendered = EmailTemplate.find_by!(key: key).preview
      assert_no_match(/\{\{/, rendered.values.join, key)
    end
  end

  test 'expiring soon uses the template' do
    mail = deliver(:credential_expiring_soon)

    assert_equal [@member.email], mail.to
    assert_includes mail.subject, 'expires soon'
    assert_includes mail.text_part.body.to_s, 'Fixture OAuth client - laptop'
    assert_includes mail.text_part.body.to_s, 'November 3, 2026'
    assert_includes mail.text_part.body.to_s, '/credentials'
  end

  test 'expired uses the template' do
    mail = deliver(:credential_expired)

    assert_includes mail.subject, 'has expired'
    assert_includes html_of(mail), 'Fixture OAuth client - laptop'
  end

  test 'revoked lists the credentials and the reason' do
    mail = deliver(:credentials_revoked)

    assert_includes mail.subject, 'revoked'
    assert_includes mail.text_part.body.to_s, '- Fixture OAuth client - laptop'
    assert_includes mail.text_part.body.to_s, 'your membership is no longer active'
    assert_includes html_of(mail), '<li>Fixture OAuth client - laptop</li>'
  end

  test 'names are escaped in the html part' do
    html = html_of(deliver(:credentials_revoked))

    assert_includes html, 'API key &lt;b&gt;x&lt;/b&gt;'
    assert_not_includes html, '<b>x</b>'
  end

  test 'an edited template is used' do
    EmailTemplate.find_by!(key: 'credential_expired').update!(subject: 'Gone: {{credential_name}}')

    assert_equal 'Gone: Fixture OAuth client - laptop', deliver(:credential_expired).subject
  end

  test 'falls back to the built-in views when a template is disabled' do
    EmailTemplate.where(key: KEYS).update_all(enabled: false)

    expiring = deliver(:credential_expiring_soon)
    expired = deliver(:credential_expired)
    revoked = deliver(:credentials_revoked)

    assert_includes expiring.subject, 'Your credential expires soon'
    assert_includes expiring.text_part.body.to_s, 'November 3, 2026'
    assert_includes expired.text_part.body.to_s, 'Fixture OAuth client - laptop'
    assert_includes revoked.text_part.body.to_s, '- API key <b>x</b>'
    assert_includes html_of(revoked), 'API key &lt;b&gt;x&lt;/b&gt;'
    assert_includes html_of(revoked), 'your membership is no longer active'
  end

  test 'string-keyed options, as read back from a queued message, work too' do
    mail = MemberMailer.credential_expired(@member, 'credential_name' => 'Stringy', 'credential_expires_at' => 'Today')

    assert_includes mail.text_part.body.to_s, 'Stringy'
  end

  test 'no email carries anything that looks like a secret' do
    KEYS.each do |key|
      mail = MemberMailer.public_send(key.to_sym, @member, @opts)
      [mail.subject, html_of(mail), mail.text_part.body.to_s].each do |text|
        assert_not_includes text, SECRET
      end
    end
  end

  test 'the category covers the three actions and lets a member opt out' do
    category = NotificationCategory.find('credentials')

    assert_equal KEYS.sort, category.mailer_actions.sort
    assert NotificationCategory.opt_out_allowed?('credentials')
    KEYS.each { |key| assert_equal 'credentials', NotificationCategory.for_mailer_action(key).key }
    assert_not_includes NotificationCategory::ADMIN_MAILER_ACTIONS, 'credentials_revoked'
    assert_includes NotificationCategory.grouped_for_member(@member).values.flatten.map(&:key), 'credentials'
  end

  test 'an opt-out blocks delivery of each' do
    NotificationOptOut.opt_out!(@member, category: 'credentials')

    KEYS.each do |key|
      assert Notifications::DeliveryGate.blocked?(mailer_action: key, user: @member), key
    end
    assert_not Notifications::DeliveryGate.blocked?(mailer_action: 'credentials_revoked', user: users(:two))
  end

  test 'queued mail rebuilds the mailer arguments for each action' do
    extra = { credential_name: 'N', credential_expires_at: 'D', other: 1 }
    assert_equal [@member, { credential_name: 'N', credential_expires_at: 'D' }],
                 QueuedMailMailerArgs::StandardArgs.build('credential_expired', @member, nil, extra)
    assert_equal [@member, { credential_names: %w[a], credential_reason: 'r' }],
                 QueuedMailMailerArgs::StandardArgs.build('credentials_revoked', @member, nil,
                                                          { credential_names: %w[a], credential_reason: 'r', x: 1 })
  end
end
