require 'application_system_test_case'

# A member requests a credential, sees the secret once, and finds only its first and last four
# characters afterwards. The controller tests cover the rules and headers; what only a browser
# shows is that the full-page form really reaches the show-once page, that Copy buttons are
# there to use, and that the secret is gone when the member moves on.
class CredentialsTest < ApplicationSystemTestCase
  SECRET = 'abcd-secret-value-wxyz'.freeze

  setup do
    @provider = create_credential_provider(name: 'Fixture apps')
    sign_in_through_form(local_accounts(:regular_member).email, 'memberpassword123')
    assert_text 'Hi, Regular Member'
  end

  test 'request a credential, see it once, then find only the hints and revoke it' do
    visit credentials_path
    assert_text 'Your credentials'
    assert_text "You don't have any credentials yet"

    click_on 'Fixture OAuth client'
    assert_text 'Request Fixture OAuth client'
    fill_in 'label', with: 'my laptop'
    click_on 'Request credential'

    assert_text 'Your new credential'
    assert_text 'Copy this now'
    assert_field 'Client secret', with: SECRET, readonly: true
    assert_button 'Copy', count: 2

    click_on "I've saved this"

    assert_text 'my laptop'
    assert_text 'abcd…wxyz'
    assert_no_text SECRET

    accept_confirm { click_on 'Revoke' }

    assert_text 'Credential revoked.'
    assert_text 'Revoked'
    assert_no_button 'Revoke'
    assert_no_text SECRET
  end

  test 'going back after the secret was shown does not show it again' do
    visit new_credential_path(provider_id: @provider.id)
    click_on 'Request credential'
    assert_field 'Client secret', with: SECRET

    click_on "I've saved this"
    page.go_back

    assert_no_field 'Client secret', with: SECRET
    assert_no_text SECRET
  end
end
