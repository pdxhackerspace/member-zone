require 'test_helper'
require 'active_job/test_helper'

class AuthentikUsersControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'sync enqueues job when authentik source is enabled' do
    assert_enqueued_with(job: Authentik::GroupSyncJob) do
      post sync_authentik_users_path
    end
    assert_redirected_to authentik_users_path
  end

  test 'sync redirects with alert when authentik source is disabled' do
    member_sources(:authentik).update!(enabled: false)

    assert_no_enqueued_jobs(only: Authentik::GroupSyncJob) do
      post sync_authentik_users_path
    end
    assert_redirected_to authentik_users_path
    assert_equal 'Authentik source is disabled.', flash[:alert]
  end

  # Whether an account is linked and whether it is active used to share one param, so you
  # could not ask for both at once. They are separate axes now, and the old links still work.
  test 'index filters on the link and account axes at the same time' do
    linked_active = AuthentikUser.create!(authentik_id: 'axes-linked-active', username: 'axes-linked-active',
                                          full_name: 'Axes Linked Active', is_active: true,
                                          user: users(:member_with_local_account), raw_attributes: {})
    unlinked_inactive = AuthentikUser.create!(authentik_id: 'axes-unlinked-inactive',
                                              username: 'axes-unlinked-inactive',
                                              full_name: 'Axes Unlinked Inactive', is_active: false,
                                              raw_attributes: {})

    get authentik_users_path(filter: 'unlinked', status: 'inactive')

    assert_response :success
    assert_select 'a[href=?]', authentik_user_path(unlinked_inactive)
    assert_select 'a[href=?]', authentik_user_path(linked_active), count: 0
  end

  test 'index still honours the old single filter param for account status' do
    inactive = AuthentikUser.create!(authentik_id: 'legacy-inactive', username: 'legacy-inactive',
                                     full_name: 'Legacy Inactive', is_active: false, raw_attributes: {})
    active = AuthentikUser.create!(authentik_id: 'legacy-active', username: 'legacy-active',
                                   full_name: 'Legacy Active', is_active: true, raw_attributes: {})

    get authentik_users_path(filter: 'inactive')

    assert_response :success
    assert_select 'a[href=?]', authentik_user_path(inactive)
    assert_select 'a[href=?]', authentik_user_path(active), count: 0
  end

  test 'index does not show the email column' do
    AuthentikUser.create!(
      authentik_id: 'authentik-index-privacy',
      username: 'auth-index-privacy',
      email: 'authentik-index-private@example.com',
      full_name: 'Authentik Index Privacy',
      raw_attributes: { email: 'authentik-index-private@example.com' }
    )

    get authentik_users_path

    assert_response :success
    assert_select 'th', text: 'Email', count: 0
    assert_select 'a[href^=?]', 'mailto:', count: 0
  end

  test 'show masks email and raw attributes with reveal control' do
    authentik_user = AuthentikUser.create!(
      authentik_id: 'authentik-detail-privacy',
      username: 'auth-detail-privacy',
      email: 'authentik-detail-private@example.com',
      full_name: 'Authentik Detail Privacy',
      raw_attributes: {
        email: 'authentik-detail-private@example.com',
        groups: ['members']
      }
    )

    get authentik_user_path(authentik_user)

    assert_response :success
    assert_select '[data-controller=?]', 'sensitive-reveal'
    assert_select '[data-action=?]', 'click->sensitive-reveal#toggle', text: /Show contact details/
    assert_select '[data-sensitive-reveal-target=?]', 'blurred', text: /authentik-detail-private@example\.com/
    assert_select 'pre[data-sensitive-reveal-target=?]', 'blurred', text: /groups/
  end

  test 'unlink_user disassociates authentik user and clears matching member authentik id' do
    user = users(:two)
    authentik_user = AuthentikUser.create!(
      authentik_id: user.authentik_id,
      username: 'auth-user',
      email: 'auth@example.com',
      full_name: 'Auth User',
      user: user
    )

    post unlink_user_authentik_user_path(authentik_user)

    assert_redirected_to authentik_user_path(authentik_user)
    assert_nil authentik_user.reload.user_id
    assert_nil user.reload.authentik_id
    assert_not user.authentik_dirty?
  end

  private

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
