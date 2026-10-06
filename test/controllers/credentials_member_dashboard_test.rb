require 'test_helper'

class CredentialsMemberDashboardTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'the profile offers your credentials when a self-service provider exists' do
    create_credential_provider
    member = sign_in_as_plain_member

    get user_path(member)

    assert_select 'a.action-card[href=?]', credentials_path, text: /Your credentials/
  end

  test 'the card is not offered when there is nothing to request and nothing issued' do
    CredentialProvider.delete_all
    member = sign_in_as_plain_member

    get user_path(member)

    assert_select 'a[href=?]', credentials_path, count: 0
  end

  test 'a member who holds credentials still sees the card when the provider is administrator-only' do
    provider = create_credential_provider(self_service: false)
    member = sign_in_as_plain_member
    create_credential(provider: provider, user: member)

    get user_path(member)

    assert_select 'a.action-card[href=?]', credentials_path
  end

  test 'the member journal tab renders credential entries for those who can see it' do
    member = create_member
    credential = create_credential(provider: create_credential_provider(name: 'Journal provider'), user: member,
                                   label: 'ci runner')
    credential.journal!('credential_issued')
    sign_in_as_admin

    get user_path(member, tab: 'journal')

    assert_response :success
    assert_select 'strong', text: 'Journal provider'
    assert_select 'span.text-muted', text: '(ci runner)'
  end
end
