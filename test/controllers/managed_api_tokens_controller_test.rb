require 'test_helper'

class ManagedApiTokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @kiosk = create_service_account(full_name: 'Front Desk Kiosk')
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'needs api.tokens.manage' do
    member = sign_in_as_plain_member
    get managed_api_tokens_path

    assert_redirected_to user_path(member)
  end

  test 'lists every token with attention counts' do
    manager = sign_in_as_manager
    member = users(:two)
    ApiToken.create!(user: member, created_by: member, name: 'Member token', expires_at: 5.days.from_now)
    ApiToken.create!(user: @kiosk, created_by: manager, name: 'Kiosk token')

    get managed_api_tokens_path

    assert_response :success
    assert_includes response.body, 'Member token'
    assert_includes response.body, 'Kiosk token'
    assert_includes response.body, 'expiring within 30 days'
  end

  test 'filters by state and holder kind' do
    manager = sign_in_as_manager
    member = users(:two)
    revoked = ApiToken.create!(user: member, created_by: member, name: 'Old member token')
    revoked.revoke!(by: member)
    ApiToken.create!(user: @kiosk, created_by: manager, name: 'Kiosk token')

    get managed_api_tokens_path(filter: 'revoked')
    assert_includes response.body, 'Old member token'
    assert_not_includes response.body, 'Kiosk token'

    get managed_api_tokens_path(kind: 'service')
    assert_includes response.body, 'Kiosk token'
    assert_not_includes response.body, 'Old member token'
  end

  test 'flags tokens with nobody to remind' do
    manager = sign_in_as_manager
    contact = users(:two)
    ApiToken.create!(user: @kiosk, created_by: manager, contact_user: contact, name: 'Orphaned kiosk token')
    contact.update_columns(active: false, membership_state: 'inactive_member')

    get managed_api_tokens_path(filter: 'no_contact')

    assert_includes response.body, 'Orphaned kiosk token'
    assert_includes response.body, '(inactive)'
  end

  test 'creates a token for a service account' do
    manager = sign_in_as_manager
    grant_privileges(@kiosk, 'api.users.search')
    grant_privileges(manager, 'api.users.search')

    assert_difference -> { @kiosk.api_tokens.count }, 1 do
      post managed_api_tokens_path, params: {
        api_token: { user_id: @kiosk.id, name: 'Kiosk', contact_user_id: users(:two).id, scopes: ['api.users.search'] }
      }
    end

    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    token = @kiosk.api_tokens.last
    assert_equal manager, token.created_by
    assert_equal users(:two), token.contact_user
    assert_equal ['api.users.search'], token.scopes
    assert_match(/mz_[A-Za-z0-9_-]+/, response.body)
  end

  test 'only service accounts can be chosen' do
    sign_in_as_manager

    assert_no_difference -> { ApiToken.count } do
      post managed_api_tokens_path, params: { api_token: { user_id: users(:two).id, name: 'Not a service account' } }
    end

    assert_response :unprocessable_content
  end

  test 'a scope the service account does not hold is refused' do
    sign_in_as_manager

    post managed_api_tokens_path, params: {
      api_token: { user_id: @kiosk.id, name: 'Kiosk', scopes: ['parking.manage_notices'] }
    }

    assert_response :unprocessable_content
  end

  test 'reassigns the contact' do
    manager = sign_in_as_manager
    token = ApiToken.create!(user: @kiosk, created_by: manager, name: 'Kiosk')

    patch managed_api_token_path(token), params: { api_token: { contact_user_id: users(:two).id, name: 'Front desk' } }

    assert_redirected_to managed_api_tokens_path
    assert_equal users(:two), token.reload.contact_user
    assert_equal 'Front desk', token.name
  end

  test 'sets the maximum lifetime' do
    sign_in_as_manager
    patch lifetime_managed_api_tokens_path, params: { api_token_max_lifetime_days: 90 }

    assert_redirected_to managed_api_tokens_path
    assert_equal 90, DefaultSetting.instance.api_token_max_lifetime_days
  end

  test 'refuses a nonsensical lifetime' do
    sign_in_as_manager
    patch lifetime_managed_api_tokens_path, params: { api_token_max_lifetime_days: 0 }

    assert_redirected_to managed_api_tokens_path
    assert flash[:alert].present?
    assert_equal 365, DefaultSetting.instance.api_token_max_lifetime_days
  end

  test 'appears in the settings hub for managers' do
    sign_in_as_manager
    get settings_path

    assert_select 'a[href=?]', managed_api_tokens_path
  end

  private

  def sign_in_as_manager
    manager = sign_in_as_plain_member
    grant_privileges(manager, 'api.tokens.manage')
    manager
  end
end
