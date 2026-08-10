require 'test_helper'

class UsersActivateDeactivateTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin

    @regular_user = users(:one)
    @regular_user.update_columns(service_account: false, membership_state: 'current_member',
                                 membership_status: 'paying', dues_status: 'current', active: true)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # ─── Activate ──────────────────────────────────────────────────────

  test 'activate rejects non-service accounts' do
    post activate_user_path(@regular_user)
    assert_redirected_to user_path(@regular_user)
    follow_redirect!
    assert_match(/determined by membership and dues status/, response.body)
  end

  test 'activate works for service accounts' do
    sa = create_service_account(active: false)
    post activate_user_path(sa)
    assert_redirected_to user_path(sa)
    sa.reload
    assert sa.active?, 'service account should be activated'
  end

  # ─── Deactivate ────────────────────────────────────────────────────

  test 'deactivate rejects non-service accounts' do
    post deactivate_user_path(@regular_user)
    assert_redirected_to user_path(@regular_user)
    follow_redirect!
    assert_match(/determined by membership and dues status/, response.body)
  end

  test 'deactivate works for service accounts' do
    sa = create_service_account(active: true)
    post deactivate_user_path(sa)
    assert_redirected_to user_path(sa)
    sa.reload
    assert_not sa.active?, 'service account should be deactivated'
  end

  # ─── Ban ───────────────────────────────────────────────────────────

  test 'ban sets membership status and compute_active_status deactivates' do
    post ban_user_path(@regular_user)
    assert_redirected_to user_path(@regular_user)
    @regular_user.reload
    assert_equal 'banned_member', @regular_user.membership_state
    assert_not @regular_user.active?, 'banned member should be inactive'
  end

  # ─── Mark Deceased ─────────────────────────────────────────────────

  test 'mark_deceased sets membership status and compute_active_status deactivates' do
    post mark_deceased_user_path(@regular_user)
    assert_redirected_to user_path(@regular_user)
    @regular_user.reload
    assert_equal 'deceased_member', @regular_user.membership_state
    assert_not @regular_user.active?, 'deceased member should be inactive'
    assert_equal 'inactive', @regular_user.payment_type
  end

  # ─── Edit form: active param protection ────────────────────────────

  test 'editing a non-service account cannot set active directly' do
    @regular_user.update_columns(membership_state: 'banned_member', active: false)
    patch user_path(@regular_user), params: { user: { active: '1', full_name: 'Updated Name' } }
    @regular_user.reload
    assert_not @regular_user.active?, 'active should not be settable via form for non-service accounts'
    assert_equal 'Updated Name', @regular_user.full_name
  end

  test 'editing a service account can set active directly' do
    sa = create_service_account(active: false)
    patch user_path(sa), params: { user: { active: '1' } }
    sa.reload
    assert sa.active?, 'service account active should be settable via form'
  end

  # ─── Emergency active override ─────────────────────────────────────

  test 'enable_emergency_active_override forces inactive member active' do
    @regular_user.update_columns(membership_state: 'inactive_member', active: false,
                                 emergency_active_override: false, service_account: false)
    post enable_emergency_active_override_user_path(@regular_user)
    assert_redirected_to user_path(@regular_user)
    @regular_user.reload
    assert @regular_user.emergency_active_override?
    assert @regular_user.active?
  end

  test 'clear_emergency_active_override recomputes active' do
    @regular_user.update_columns(membership_state: 'inactive_member', active: true,
                                 emergency_active_override: true, service_account: false)
    post clear_emergency_active_override_user_path(@regular_user)
    assert_redirected_to user_path(@regular_user)
    @regular_user.reload
    assert_not @regular_user.emergency_active_override?
    assert_not @regular_user.active?
  end

  test 'enable_emergency_active_override rejects banned members' do
    @regular_user.update_columns(membership_state: 'banned_member', active: false,
                                 emergency_active_override: false, service_account: false)
    post enable_emergency_active_override_user_path(@regular_user)
    assert_redirected_to user_path(@regular_user)
    follow_redirect!
    assert_match(/not available/, response.body)
  end

  test 'enable_emergency_active_override rejects service accounts' do
    sa = create_service_account(active: false)
    post enable_emergency_active_override_user_path(sa)
    assert_redirected_to user_path(sa)
    follow_redirect!
    assert_match(/Service accounts/, response.body)
  end

  private

  def sign_in_as_local_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end

  def create_service_account(attrs = {})
    defaults = {
      authentik_id: "sa-ctrl-#{SecureRandom.hex(4)}",
      full_name: "Service Ctrl #{SecureRandom.hex(4)}",
      payment_type: 'unknown',
      service_account: true,
      active: true
    }
    User.create!(defaults.merge(attrs))
  end
end
