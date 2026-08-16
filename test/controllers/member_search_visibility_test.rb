require 'test_helper'

# A member who kept their profile private must not be named by a search.
#
# Three endpoints answer "which members match this string", and each one used to answer it
# differently. /search in member mode filtered on profile_visibility; /search in admin mode,
# /users and /api/users/search did not, so any non-admin holding search.admin,
# members.view_list or api.users.search searched the whole roster. The rule is now the one
# the profile page has always used: an administrator or a holder of members.view_profile
# reads every profile, everyone else reads only the shared ones plus their own.
class MemberSearchVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @private_member = users(:private_profile_user)
    @shared_member = users(:public_profile_user)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # ── /search, member mode ────────────────────────────────────────────────────

  test 'a plain member searching does not find a private profile' do
    sign_in_as_plain_member

    get search_path(q: 'Profile User')

    assert_response :success
    assert_match @shared_member.display_name, response.body
    assert_no_match @private_member.display_name, response.body
  end

  test 'a member finds their own name even after making their profile private' do
    member = sign_in_as_plain_member
    member.update!(profile_visibility: 'private')

    get search_path(q: member.full_name)

    assert_response :success
    assert_match member.display_name, response.body
  end

  test 'members.view_profile restores private profiles to a member search' do
    holder('members.view_profile')

    get search_path(q: 'Profile User')

    assert_response :success
    assert_match @private_member.display_name, response.body
  end

  # ── /search, admin mode ─────────────────────────────────────────────────────

  # search.admin adds the source records — Authentik, Slack, the sheet — behind the roster.
  # It says nothing about whose profile may be read, so it must not uncover a private one.
  test 'search.admin widens the record types without uncovering a private profile' do
    holder('search.admin')

    get search_path(q: 'Profile User')

    assert_response :success
    assert_match @shared_member.display_name, response.body
    assert_no_match @private_member.display_name, response.body
  end

  test 'an administrator searching still finds a private profile' do
    sign_in_as_admin

    get search_path(q: 'Profile User')

    assert_response :success
    assert_match @private_member.display_name, response.body
  end

  # ── /users, the member directory ────────────────────────────────────────────

  test 'members.view_list alone lists and searches only the shared members' do
    holder('members.view_list')

    get users_path(q: 'privateuser')

    assert_response :success
    assert_no_match @private_member.display_name, response.body

    get users_path(q: 'publicuser')

    assert_match @shared_member.display_name, response.body
  end

  test 'the directory total counts only the members a view_list holder may see' do
    holder('members.view_list')

    get users_path

    assert_response :success
    assert_no_match @private_member.display_name, response.body
  end

  test 'members.view_profile restores private profiles to the directory' do
    holder('members.view_list', 'members.view_profile')

    get users_path(q: 'privateuser')

    assert_response :success
    assert_match @private_member.display_name, response.body
  end

  test 'an administrator still sees every member in the directory' do
    sign_in_as_admin

    get users_path(q: 'privateuser')

    assert_response :success
    assert_match @private_member.display_name, response.body
  end

  # ── /api/users/search, the member picker ────────────────────────────────────

  # This one answers with email addresses, so a leak here is worse than a name in a list.
  test 'the picker API withholds a private member and their email address' do
    holder('api.users.search')

    get api_users_search_path(q: 'Profile User')

    assert_response :success
    assert_not_includes result_ids, @private_member.id
    assert_includes result_ids, @shared_member.id
    assert_no_match(/private@example\.com/, response.body)
  end

  test 'the picker API returns a private member to a members.view_profile holder' do
    holder('api.users.search', 'members.view_profile')

    get api_users_search_path(q: 'Profile User')

    assert_response :success
    assert_includes result_ids, @private_member.id
  end

  test 'the picker API returns a private member to an administrator' do
    sign_in_as_admin

    get api_users_search_path(q: 'Profile User')

    assert_response :success
    assert_includes result_ids, @private_member.id
  end

  private

  def result_ids
    response.parsed_body.pluck('id')
  end

  # The grant lands between two sign-ins because User#conferred_privileges is memoized per
  # instance and the session loads its own.
  def holder(*privilege_keys)
    member = sign_in_as_plain_member
    privilege_keys.each { |key| grant_privileges(member, key) }
    sign_in_as_plain_member
  end
end
