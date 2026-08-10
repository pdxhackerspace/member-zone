require 'test_helper'

class UsersSponsoredTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin

    @user = users(:one)
    @user.update_columns(is_sponsored: false)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # ─── Mark Sponsored ────────────────────────────────────────────────

  test 'mark_sponsored sets the sponsored flag' do
    post mark_sponsored_user_path(@user)
    assert_redirected_to user_path(@user)

    @user.reload
    assert @user.is_sponsored?, 'Member should be marked as sponsored'
  end

  test 'mark_sponsored activates the member' do
    @user.update_columns(membership_state: 'unknown', membership_status: 'unknown', dues_status: 'unknown',
                         active: false)

    post mark_sponsored_user_path(@user)
    @user.reload

    assert @user.is_sponsored?
    assert @user.active?, 'Sponsored member should be active'
  end

  # ─── Unmark Sponsored ──────────────────────────────────────────────

  test 'unmark_sponsored removes the sponsored flag' do
    @user.update_columns(is_sponsored: true)

    post unmark_sponsored_user_path(@user)
    assert_redirected_to user_path(@user)

    @user.reload
    assert_not @user.is_sponsored?, 'Member should no longer be sponsored'
  end

  # ─── Profile view ──────────────────────────────────────────────────

  test 'sponsored badge is visible on profile' do
    @user.update_columns(is_sponsored: true)

    get user_path(@user)
    assert_response :success
    assert_select 'span.badge', text: /Sponsored/
  end

  test 'sponsor button shows for non-sponsored member' do
    get user_path(@user)
    assert_response :success
    assert_match 'Sponsor', response.body
  end

  test 'remove sponsorship button shows for sponsored member' do
    @user.update_columns(is_sponsored: true)

    get user_path(@user)
    assert_response :success
    assert_match 'Remove Sponsorship', response.body
  end

  test 'payment type is hidden for sponsored member without payment info' do
    @user.update_columns(is_sponsored: true, payment_type: 'unknown', membership_plan_id: nil)

    get user_path(@user)
    assert_response :success
    assert_no_match(/Payment Type/, response.body)
  end

  private

  def sign_in_as_local_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
