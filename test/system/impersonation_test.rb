require 'application_system_test_case'

# Impersonation is the highest-consequence invariant in the app: current_user becomes the
# impersonated member so views render as them, while true_user stays the real admin and is what
# every authorization check must resolve against. The way back out has to work whatever the
# impersonated member is allowed to do.
#
# Controller tests cover the authorization rules. What they cannot cover is the round trip as a
# session — entering, seeing the app as someone else, and getting back — which is the part that
# breaks if the banner or the exit control regresses.
class ImpersonationTest < ApplicationSystemTestCase
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @admin_account = local_accounts(:active_admin)
    @member = users(:one)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'an admin can impersonate a member and get back out again' do
    sign_in_as_admin_through_form

    visit user_path(@member)
    accept_confirm { click_on 'Impersonate' }

    assert_text "You are now viewing as #{@member.display_name}"

    # The banner is the only thing telling an admin they are not themselves, so its absence is a
    # security problem rather than a cosmetic one.
    assert_text 'Stop Impersonating'

    click_on 'Stop Impersonating'

    assert_text 'Impersonation ended'
    assert_no_text 'Stop Impersonating'
  end

  test 'the impersonated member sees no Impersonate button to chain onward' do
    sign_in_as_admin_through_form

    visit user_path(@member)
    accept_confirm { click_on 'Impersonate' }
    assert_text "You are now viewing as #{@member.display_name}"

    visit user_path(users(:two))

    assert_no_button 'Impersonate'
  end

  test 'a member who is not an admin is never offered impersonation' do
    sign_in_through_form(local_accounts(:regular_member).email, 'memberpassword123')

    visit user_path(@member)

    assert_no_button 'Impersonate'
  end

  private

  def sign_in_as_admin_through_form
    sign_in_through_form(@admin_account.email, 'localpassword123')
    assert_text 'Signed in locally'
  end
end
