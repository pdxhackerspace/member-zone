require 'application_system_test_case'

# The password sign-in form as a member meets it. The controller tests already assert the status
# codes and the markup; what they cannot assert is that filling the form in and pressing the button
# actually signs someone in, which is the one thing every other system test depends on.
class LocalSignInTest < ApplicationSystemTestCase
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @account = local_accounts(:active_admin)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'a member signs in with their password' do
    sign_in_through_form(@account.email, 'localpassword123')

    assert_text 'Signed in locally'
  end

  test 'a wrong password is refused beside the form, with the address still filled in' do
    sign_in_through_form(@account.email, 'wrongpassword')

    assert_text 'Invalid email or password'
    assert_field 'session[email]', with: @account.email
    assert_field 'session[password]', with: ''
  end

  # Asserted on the absence of a session rather than on the "Signed out successfully" notice. That
  # notice is set on a redirect to root, and root redirects again for anyone not signed in, which
  # replaces the flash with "Please sign in to continue" before it is ever rendered.
  test 'signing out ends the session' do
    sign_in_through_form(@account.email, 'localpassword123')
    assert_text 'Signed in locally'

    click_on 'Sign out'

    assert_current_path login_path
    assert_no_text 'Sign out'
    assert_field 'session[email]'
  end
end
