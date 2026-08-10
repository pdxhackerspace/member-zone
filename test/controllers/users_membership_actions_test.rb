require 'test_helper'

# The member page offers these actions whatever state a member is in, so each one has to
# say plainly when it declined rather than flashing success over a no-op.
class UsersMembershipActionsTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin

    @user = users(:one)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'banning a member who is already banned reports that it did nothing' do
    @user.update_columns(membership_state: 'banned_member')

    post ban_user_path(@user)

    assert_redirected_to user_path(@user)
    assert_match(/cannot be banned/, flash[:alert])
    assert_equal 'banned_member', @user.reload.membership_state
  end

  test 'banning a deceased member reports that it did nothing' do
    @user.update_columns(membership_state: 'deceased_member')

    post ban_user_path(@user)

    assert_match(/cannot be banned from deceased member/, flash[:alert])
    assert_equal 'deceased_member', @user.reload.membership_state
  end

  test 'banning a current member still succeeds' do
    @user.update_columns(membership_state: 'current_member')

    post ban_user_path(@user)

    assert_equal 'Member banned.', flash[:notice]
    assert_equal 'banned_member', @user.reload.membership_state
  end

  test 'marking an already deceased member reports that it did nothing' do
    @user.update_columns(membership_state: 'deceased_member')

    post mark_deceased_user_path(@user)

    assert_match(/already recorded as deceased/, flash[:alert])
  end

  test 'sponsoring a deceased member reports that it did nothing' do
    @user.update_columns(membership_state: 'deceased_member', is_sponsored: false)

    post mark_sponsored_user_path(@user)

    assert_match(/cannot be sponsored from deceased member/, flash[:alert])
    assert_equal 'deceased_member', @user.reload.membership_state
    assert_not @user.is_sponsored?
  end

  test 'sponsoring does not queue the sponsorship email when it was refused' do
    @user.update_columns(membership_state: 'deceased_member', is_sponsored: false)

    assert_no_difference 'QueuedMail.count' do
      post mark_sponsored_user_path(@user)
    end
  end

  test 'removing sponsorship from a member who is not sponsored reports that it did nothing' do
    @user.update_columns(membership_state: 'current_member', is_sponsored: false)

    post unmark_sponsored_user_path(@user)

    assert_match(/is not sponsored/, flash[:alert])
    assert_equal 'current_member', @user.reload.membership_state
  end

  test 'recording a cancellation for a deceased member reports that it did nothing' do
    @user.update_columns(membership_state: 'deceased_member')

    post record_cancellation_user_path(@user)

    assert_match(/cannot be recorded/, flash[:alert])
    assert_equal 'deceased_member', @user.reload.membership_state
  end

  private

  def sign_in_as_local_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
