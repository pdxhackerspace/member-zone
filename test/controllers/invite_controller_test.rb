require 'test_helper'

class InviteControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # GET /invite/:token — show page

  test 'shows acceptance form for a pending invitation' do
    get invite_path(invitations(:pending).token)
    assert_response :success
    assert_select 'form'
    assert_match invitations(:pending).email, response.body
  end

  test 'shows expired error for an expired invitation' do
    get invite_path(invitations(:expired).token)
    assert_response :success
    assert_match(/Invitation Expired/i, response.body)
    assert_select 'form', count: 0
  end

  test 'shows cancelled/invalid error for a cancelled invitation' do
    get invite_path(invitations(:cancelled).token)
    assert_response :success
    assert_match(/Invalid Invitation/i, response.body)
  end

  test 'shows not-found error for an unknown token' do
    get invite_path('totally-bogus-token-xyz')
    assert_response :success
    assert_match(/Invitation Not Found/i, response.body)
  end

  # Already-accepted: auto-login and redirect

  test 'auto-logs in user and redirects when invitation is already accepted' do
    accepted = invitations(:accepted)
    assert accepted.user.present?, 'fixture must have an associated user'

    get invite_path(accepted.token)

    assert_redirected_to root_path
    follow_redirect!
    # root_path redirects to user profile when logged in
    follow_redirect! while response.redirect?
    assert_response :success
  end

  test 'session is set to the accepted user when revisiting an accepted invitation' do
    accepted = invitations(:accepted)
    get invite_path(accepted.token)

    # Follow all redirects (invite → root → user profile)
    follow_redirect! while response.redirect?
    assert_response :success
    # Subsequent authenticated request should succeed
    get root_path
    follow_redirect! while response.redirect?
    assert_response :success
  end

  # POST /invite/:token/accept

  test 'creates user, logs them in, and redirects to profile setup' do
    invitation = invitations(:pending)

    assert_difference 'User.count', 1 do
      post accept_invite_path(invitation.token), params: {
        user: { full_name: 'New Member', username: 'newmember123' }
      }
    end

    assert_redirected_to profile_setup_path
    new_user = User.lookup_by_email(invitation.email)
    assert_not_nil new_user
  end

  test 'marks the invitation as accepted after signup' do
    invitation = invitations(:pending)
    post accept_invite_path(invitation.token), params: {
      user: { full_name: 'New Member', username: 'newmember789' }
    }
    assert_predicate invitation.reload, :accepted?
  end

  test 'renders form with errors when full_name is blank' do
    invitation = invitations(:pending)
    assert_no_difference 'User.count' do
      post accept_invite_path(invitation.token), params: {
        user: { full_name: '', username: 'newmember' }
      }
    end
    assert_response :unprocessable_entity
  end

  test 'rejects accept on an expired invitation' do
    assert_no_difference 'User.count' do
      post accept_invite_path(invitations(:expired).token), params: {
        user: { full_name: 'Late Joiner', username: 'latejoiner' }
      }
    end
    assert_response :success
    assert_match(/Invitation Expired/i, response.body)
  end

  test 'rejects accept on a cancelled invitation' do
    assert_no_difference 'User.count' do
      post accept_invite_path(invitations(:cancelled).token), params: {
        user: { full_name: 'Late Joiner', username: 'latejoiner2' }
      }
    end
    assert_response :success
    assert_match(/Invalid Invitation/i, response.body)
  end
end
