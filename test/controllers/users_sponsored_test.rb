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

  test 'the edit form sends sponsorship changes to the profile action' do
    get edit_user_path(@user)

    assert_response :success
    assert_match(/Sponsor action on the member profile/, response.body)
    assert_no_match(/value="sponsored_member"/, response.body)

    @user.mark_sponsored!
    get edit_user_path(@user)

    assert_response :success
    assert_match(/Use the Sponsor action on the member profile to change sponsorship/, response.body)
    assert_no_match(/<select[^>]*id="user_membership_state"/, response.body)
  end

  test 'editing membership state off sponsored is refused' do
    @user.mark_sponsored!

    patch user_path(@user), params: { user: { membership_state: 'current_member', full_name: 'Renamed Anyway' } }

    assert_redirected_to edit_user_path(@user)
    assert_match(/Sponsor action/, flash[:alert])
    @user.reload
    assert_equal 'sponsored_member', @user.membership_state
    assert_not_equal 'Renamed Anyway', @user.full_name
  end

  test 'editing membership state onto sponsored is refused' do
    patch user_path(@user), params: { user: { membership_state: 'sponsored_member' } }

    assert_redirected_to edit_user_path(@user)
    assert_match(/Sponsor action/, flash[:alert])
    assert_not @user.reload.sponsored_member?
  end

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
