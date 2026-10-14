require 'test_helper'

class ApiTokenMailerTest < ActionMailer::TestCase
  setup do
    EmailTemplate.seed_defaults!
    @member = users(:two)
    @token = ApiToken.create!(user: @member, created_by: @member, name: 'Parking script', expires_at: 10.days.from_now)
  end

  test 'the template is seeded and its variables are documented, sampled, and offered in the editor' do
    template = EmailTemplate.find_by!(key: 'api_token_expiring_soon')
    assert template.enabled?

    attrs = EmailTemplate::DEFAULT_TEMPLATES.fetch('api_token_expiring_soon')
    tokens = attrs.values_at(:subject, :body_html, :body_text).join("\n").scan(/\{\{([^}]+)\}\}/).flatten.uniq
    tokens.each do |token|
      assert EmailTemplate::AVAILABLE_VARIABLES.key?("{{#{token}}}"), "{{#{token}}} is undocumented"
      assert EmailTemplate::PreviewVariables.all.key?(token.to_sym), "{{#{token}}} has no sample"
      assert EmailTemplate.editor_variables_for('api_token_expiring_soon').key?("{{#{token}}}"),
             "{{#{token}}} not in the editor"
    end
  end

  test 'names the token, its hint, and the expiry, and links the holder to their tokens page' do
    mail = MemberMailer.api_token_expiring_soon(@member, api_token_id: @token.id)

    assert_equal [@member.email], mail.to
    assert_includes mail.subject, 'Parking script'
    body = mail.text_part.body.to_s
    assert_includes body, @token.token_hint
    assert_includes body, @token.expires_at.strftime('%B %-d, %Y')
    assert_includes body, '/api_tokens'
    assert_not_includes body, '/settings/api_tokens'
  end

  test 'links a token manager to the settings page' do
    manager = users(:one)
    mail = MemberMailer.api_token_expiring_soon(manager, api_token_id: @token.id)

    assert_equal [manager.email], mail.to
    assert_includes mail.text_part.body.to_s, '/settings/api_tokens'
  end

  test "links a service token's contact to their own tokens page" do
    admin = users(:one)
    admin.update_columns(is_admin: true)
    token = ApiToken.create!(user: create_service_account, created_by: admin, contact_user: @member, name: 'Kiosk')
    mail = MemberMailer.api_token_expiring_soon(@member, api_token_id: token.id)

    assert_includes mail.text_part.body.to_s, '/api_tokens'
    assert_not_includes mail.text_part.body.to_s, '/settings/api_tokens'
  end

  test 'falls back to the view when the template is disabled' do
    EmailTemplate.find_by!(key: 'api_token_expiring_soon').update!(enabled: false)
    mail = MemberMailer.api_token_expiring_soon(@member, api_token_id: @token.id)

    assert_includes mail.subject, 'Parking script'
    assert_includes mail.text_part.body.to_s, @token.token_hint
  end

  test 'sends nothing for a token that no longer exists' do
    mail = MemberMailer.api_token_expiring_soon(@member, api_token_id: 0)

    assert_nil mail.message.to
  end
end
