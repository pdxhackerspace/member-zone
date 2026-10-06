require 'test_helper'

class IssuedCredentialsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @provider = create_credential_provider(name: 'Apps')
    @member = create_member(name: 'Alice Issued')
    @credential = create_credential(provider: @provider, user: @member, label: 'alice laptop')
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  def sign_in_viewer(*extra)
    member = sign_in_as_plain_member
    grant_privileges(member, 'credentials.view_all', *extra)
    sign_in_as_plain_member
  end

  test 'only credentials.view_all opens the list' do
    sign_in_as_plain_member

    get issued_credentials_path

    assert_response :redirect
  end

  test 'administrators and holders can open it' do
    sign_in_as_admin
    get issued_credentials_path
    assert_response :success

    sign_in_viewer
    get issued_credentials_path
    assert_response :success
  end

  test 'other credential privileges do not open it' do
    member = sign_in_as_plain_member
    grant_privileges(member, 'credentials.revoke', 'credentials.manage_providers', 'credentials.issue_for_members')
    sign_in_as_plain_member

    get issued_credentials_path

    assert_response :redirect
  end

  test 'lists every member credential with provider, status and who issued it' do
    admin = users(:two)
    create_credential(provider: @provider, user: create_member(name: 'Bob Issued'), issued_by: admin)
    sign_in_viewer

    get issued_credentials_path

    assert_select 'td a', text: 'Alice Issued'
    assert_select 'td a', text: 'Bob Issued'
    assert_select 'td', text: 'Apps', minimum: 2
    assert_select 'td', text: /Issued by #{Regexp.escape(admin.display_name)}/
    assert_not_includes response.body, 'abcd'
  end

  test 'pending rows are not listed' do
    create_credential(provider: @provider, user: @member, status: 'pending', label: 'in flight')
    sign_in_viewer

    get issued_credentials_path

    assert_select 'td', text: /in flight/, count: 0
  end

  test 'filters by provider' do
    other = create_credential_provider(name: 'Other')
    create_credential(provider: other, user: create_member(name: 'Carol Other'))
    sign_in_viewer

    get issued_credentials_path(provider_id: other.id)

    assert_select 'td a', text: 'Carol Other'
    assert_select 'td a', text: 'Alice Issued', count: 0
  end

  test 'filters by status' do
    create_credential(provider: @provider, user: create_member(name: 'Dave Revoked'), status: 'revoked')
    sign_in_viewer

    get issued_credentials_path(status: 'revoked')
    assert_select 'td a', text: 'Dave Revoked'
    assert_select 'td a', text: 'Alice Issued', count: 0

    get issued_credentials_path(status: 'nonsense')
    assert_select 'td a', text: 'Alice Issued'
  end

  test 'filters by member' do
    create_credential(provider: @provider, user: create_member(name: 'Eve Elsewhere'))
    sign_in_viewer

    get issued_credentials_path(user_id: @member.id)

    assert_select 'td a', text: 'Alice Issued'
    assert_select 'td a', text: 'Eve Elsewhere', count: 0
  end

  test 'filters to credentials expiring within two weeks' do
    @credential.update!(expires_at: 5.days.from_now)
    create_credential(provider: @provider, user: create_member(name: 'Frank Later'), expires_at: 40.days.from_now)
    create_credential(provider: @provider, user: create_member(name: 'Gina Never'))
    sign_in_viewer

    get issued_credentials_path(expiring: '1')

    assert_select 'td a', text: 'Alice Issued'
    assert_select 'td a', text: 'Frank Later', count: 0
    assert_select 'td a', text: 'Gina Never', count: 0
  end

  test 'a chip counts credentials whose revocation is failing' do
    create_credential(provider: @provider, user: create_member(name: 'Hank Failing'), status: 'revoke_failed',
                      revoke_attempts: 3)
    sign_in_viewer

    get issued_credentials_path

    assert_select '.filter-chip.danger', text: /Revocation failed\s*1/
    get issued_credentials_path(status: 'revoke_failed')
    assert_select 'td', text: /3 attempts/
  end

  test 'paginates' do
    55.times { create_credential(provider: @provider, user: @member, status: 'revoked') }
    sign_in_viewer

    get issued_credentials_path

    assert_select 'tbody tr', count: IssuedCredentialsController::PER_PAGE
    assert_select '.pagination'
    get issued_credentials_path(page: 2)
    assert_select 'tbody tr', minimum: 1
  end

  test 'revoke buttons need credentials.revoke, both ways' do
    sign_in_viewer
    get issued_credentials_path
    assert_select 'form[action=?]', revoke_credential_path(@credential), count: 0

    sign_in_viewer('credentials.revoke')
    get issued_credentials_path
    assert_select 'form[action=?]', revoke_credential_path(@credential), count: 1
  end

  test 'a revoke button posts through to a real revoke' do
    sign_in_viewer('credentials.revoke')

    post revoke_credential_path(@credential)

    assert_equal 'revoked', @credential.reload.status
  end

  test 'rotate buttons and the issue-for-member form need credentials.issue_for_members, both ways' do
    sign_in_viewer
    get issued_credentials_path
    assert_select 'form[action=?]', rotate_credential_path(@credential), count: 0
    assert_select 'form[action=?]', new_credential_path, count: 0

    sign_in_viewer('credentials.issue_for_members')
    get issued_credentials_path
    assert_select 'form[action=?]', rotate_credential_path(@credential), count: 1
    assert_select 'form[action=?][method=get]', new_credential_path do
      assert_select 'select[name=provider_id] option', text: 'Apps'
      assert_select 'input[name=member_email]'
    end
  end

  test 'the Admin navigation links here for view_all holders only' do
    plain = sign_in_as_plain_member
    get user_path(plain)
    assert_select 'a[href=?]', issued_credentials_path, count: 0

    viewer = sign_in_viewer
    get user_path(viewer)
    assert_select 'a[href=?]', issued_credentials_path, minimum: 1
  end
end
