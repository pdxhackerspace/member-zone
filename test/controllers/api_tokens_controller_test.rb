require 'test_helper'

class ApiTokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'every action needs a signed-in member' do
    get api_tokens_path
    assert_redirected_to login_path
  end

  test 'lists only your own tokens' do
    member = sign_in_as_plain_member
    ApiToken.create!(user: member, created_by: member, name: 'Mine')
    other = users(:two)
    ApiToken.create!(user: other, created_by: other, name: 'Not mine')

    get api_tokens_path

    assert_response :success
    assert_includes response.body, 'Mine'
    assert_not_includes response.body, 'Not mine'
  end

  test 'the new form offers the scopes you hold' do
    sign_in_as_plain_member
    get new_api_token_path

    assert_response :success
    assert_select 'input[type=checkbox][value=?]', 'parking.own_permits'
    assert_select 'input[type=checkbox][value=?]', 'parking.manage_notices', count: 0
  end

  test 'creating a token shows the secret once, uncached, and stores only its digest' do
    member = sign_in_as_plain_member

    assert_difference -> { member.api_tokens.count }, 1 do
      post api_tokens_path, params: { api_token: { name: 'Parking script', scopes: ['parking.own_permits'] } }
    end

    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    secret = response.body[/mz_[A-Za-z0-9_-]+/]
    token = member.api_tokens.last
    assert_equal ApiToken.digest(secret), token.token_digest
    assert_equal ['parking.own_permits'], token.scopes
    assert_equal member, token.contact_user
    assert Journal.exists?(action: 'api_token_created', user: member)
  end

  test 'a scope you do not hold is refused' do
    member = sign_in_as_plain_member

    assert_no_difference -> { member.api_tokens.count } do
      post api_tokens_path, params: { api_token: { name: 'Sneaky', scopes: ['parking.manage_notices'] } }
    end

    assert_response :unprocessable_content
  end

  test 'a name is required' do
    sign_in_as_plain_member
    post api_tokens_path, params: { api_token: { name: '' } }

    assert_response :unprocessable_content
  end

  test 'you can extend, suspend, resume, and revoke your own token' do
    member = sign_in_as_plain_member
    token = ApiToken.create!(user: member, created_by: member, name: 'Mine')
    token.update_columns(expires_at: 2.days.ago)

    post renew_api_token_path(token)
    assert_redirected_to api_tokens_path
    assert token.reload.expires_at.future?

    post suspend_api_token_path(token)
    assert token.reload.suspended?
    assert_equal member, token.suspended_by

    post resume_api_token_path(token)
    assert_not token.reload.suspended?

    post revoke_api_token_path(token)
    assert token.reload.revoked?
  end

  test 'a revoked token cannot be extended' do
    member = sign_in_as_plain_member
    token = ApiToken.create!(user: member, created_by: member, name: 'Mine')
    token.revoke!(by: member)

    post renew_api_token_path(token)

    assert_redirected_to api_tokens_path
    assert_match(/revoked token cannot be extended/, flash[:alert])
  end

  test 'you can see and extend service tokens you are the contact for' do
    member = sign_in_as_plain_member
    admin = users(:one)
    admin.update_columns(is_admin: true)
    kiosk = create_service_account(full_name: 'Front Desk Kiosk')
    token = ApiToken.create!(user: kiosk, created_by: admin, contact_user: member, name: 'Kiosk token')
    token.update_columns(expires_at: 1.day.from_now)

    get api_tokens_path
    assert_includes response.body, 'Tokens you look after'
    assert_includes response.body, 'Kiosk token'

    post renew_api_token_path(token)
    assert_redirected_to api_tokens_path
    assert token.reload.expires_at > 300.days.from_now
  end

  test "you cannot touch someone else's token" do
    sign_in_as_plain_member
    other = users(:two)
    token = ApiToken.create!(user: other, created_by: other, name: 'Theirs')

    post revoke_api_token_path(token)

    assert_response :not_found
    assert_not token.reload.revoked?
  end

  test "a token manager can act on anyone's token" do
    manager = sign_in_as_plain_member
    grant_privileges(manager, 'api.tokens.manage')
    other = users(:two)
    token = ApiToken.create!(user: other, created_by: other, name: 'Theirs')

    post suspend_api_token_path(token), headers: { 'HTTP_REFERER' => managed_api_tokens_url }

    assert_redirected_to managed_api_tokens_url
    assert token.reload.suspended?
    assert_equal manager, token.suspended_by
  end

  test 'tokens cannot be created or changed while impersonating' do
    member = users(:two)
    token = ApiToken.create!(user: member, created_by: member, name: 'Mine')
    impersonate(member)

    assert_no_difference -> { ApiToken.count } do
      post api_tokens_path, params: { api_token: { name: 'Minted while impersonating' } }
    end
    assert_redirected_to api_tokens_path

    post revoke_api_token_path(token)
    assert_not token.reload.revoked?
  end

  private

  def impersonate(member)
    sign_in_as_admin
    post impersonate_user_path(user_id: member.id)
    assert_equal member.id, session[:impersonated_user_id]
  end
end
