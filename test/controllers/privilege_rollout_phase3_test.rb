require 'test_helper'

# The member actions and settings destinations, converted from administrator-only to their
# own privileges. Each pair is the contract: the holder acts, a plain member is refused.
class PrivilegeRolloutPhase3Test < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @member = users(:one)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # ─── Member status actions ────────────────────────────────────────────

  test 'members.ban bans, and nothing else does' do
    sign_in_as_plain_member
    post ban_user_path(@member)
    assert_not_equal 'banned', @member.reload.membership_status

    holder('members.ban')
    post ban_user_path(@member)
    assert_equal 'banned', @member.reload.membership_status
  end

  test 'members.mark_deceased marks deceased, and nothing else does' do
    sign_in_as_plain_member
    post mark_deceased_user_path(@member)
    assert_not_equal 'deceased', @member.reload.membership_status

    holder('members.mark_deceased')
    post mark_deceased_user_path(@member)
    assert_equal 'deceased', @member.reload.membership_status
  end

  test 'members.sponsor sponsors, and nothing else does' do
    sign_in_as_plain_member
    post mark_sponsored_user_path(@member)
    assert_not_predicate @member.reload, :is_sponsored?

    holder('members.sponsor')
    post mark_sponsored_user_path(@member)
    assert_predicate @member.reload, :is_sponsored?
  end

  test 'members.delete deletes, and nothing else does' do
    target = User.create!(authentik_id: 'phase3-delete-me', full_name: 'Delete Me')

    sign_in_as_plain_member
    assert_no_difference 'User.count' do
      delete user_path(target)
    end

    holder('members.delete')
    assert_difference 'User.count', -1 do
      delete user_path(target)
    end
  end

  test 'members.create opens the new member form, and nothing else does' do
    sign_in_as_plain_member
    get new_user_path
    assert_response :redirect

    holder('members.create')
    get new_user_path
    assert_response :success
  end

  test 'members.sync_authentik reaches the push action, and nothing else does' do
    sign_in_as_plain_member
    post sync_to_authentik_user_path(@member)
    assert_response :redirect
    assert_equal 'You do not have access to that section.', flash[:alert]

    holder('members.sync_authentik')
    post sync_to_authentik_user_path(@member)
    assert_not_equal 'You do not have access to that section.', flash[:alert]
  end

  test 'members.unlink_sources reaches the unlink actions, and nothing else does' do
    sign_in_as_plain_member
    post unlink_slack_user_path(@member)
    assert_equal 'You do not have access to that section.', flash[:alert]

    holder('members.unlink_sources')
    post unlink_slack_user_path(@member)
    assert_not_equal 'You do not have access to that section.', flash[:alert]
  end

  # ─── The per-attribute split on update ────────────────────────────────

  test 'members.edit_notes saves notes but not membership' do
    @member.update!(notes: 'before', membership_state: 'current_member')
    holder('members.edit_notes')

    patch user_path(@member), params: { user: { notes: 'after', membership_state: 'guest_member' } }

    assert_equal 'after', @member.reload.notes
    assert_equal 'current_member', @member.membership_state
  end

  test 'members.edit_profile saves contact details but not notes' do
    @member.update!(notes: 'untouched')
    holder('members.edit_profile')

    patch user_path(@member), params: { user: { phone_number: '555-0100', notes: 'changed' } }

    assert_equal '555-0100', @member.reload.phone_number
    assert_equal 'untouched', @member.notes
  end

  test 'members.edit_membership cannot unban through a membership state patch' do
    @member.update!(membership_state: 'banned_member')
    holder('members.edit_membership')

    patch user_path(@member), params: { user: { membership_state: 'current_member' } }

    assert_equal 'banned_member', @member.reload.membership_state
  end

  test 'members.grant_admin is the only way to set is_admin' do
    holder('members.edit_profile', 'members.edit_membership', 'members.edit_notes')
    patch user_path(@member), params: { user: { is_admin: true } }
    assert_not_predicate @member.reload, :is_admin?

    holder('members.grant_admin')
    patch user_path(@member), params: { user: { is_admin: true } }
    assert_predicate @member.reload, :is_admin?
  end

  # ─── The bulk Authentik operations keep no key, so they keep admin ────

  test 'no member privilege reaches the bulk Authentik syncs' do
    holder('members.view_list', 'members.view_profile', 'members.sync_authentik',
           'members.edit_profile', 'members.edit_membership')

    post sync_all_to_authentik_users_path
    assert_response :redirect
    assert_equal 'You do not have access to that section.', flash[:alert]

    post toggle_authentik_sync_inactive_as_active_users_path
    assert_equal 'You do not have access to that section.', flash[:alert]
  end

  # ─── Settings destinations ────────────────────────────────────────────

  {
    'access.manage_controllers' => :access_controllers_path,
    'access.manage_controller_types' => :access_controller_types_path,
    'access.manage_readers' => :rfid_readers_path,
    'parking.manage_rooms' => :rooms_path,
    'parking.manage_printers' => :printers_path,
    'webhooks.incoming.manage' => :incoming_webhooks_path,
    'settings.interests' => :interests_path,
    'settings.ai_providers' => :ai_providers_path,
    'settings.ai_services' => :ai_ollama_profiles_path,
    'sources.manage' => :member_sources_path,
    'payments.manage_processors' => :payment_processors_path,
    'membership_settings.manage' => :membership_settings_path,
    'settings.applications' => :applications_path,
    'applications.configure_form' => :application_form_pages_path
  }.each do |privilege, path_helper|
    test "#{privilege} opens #{path_helper}, and nothing else does" do
      sign_in_as_plain_member
      get send(path_helper)
      assert_response :redirect, "#{path_helper} should be refused without #{privilege}"

      holder(privilege)
      get send(path_helper)
      assert_response :success, "#{path_helper} should open for a #{privilege} holder"
    end
  end

  test 'each settings destination also appears as its row in the hub' do
    holder('settings.interests')

    get settings_path

    assert_response :success
    assert_select 'a[href=?]', interests_path
    assert_select 'a[href=?]', rooms_path, count: 0
  end

  private

  def holder(*privilege_keys)
    member = sign_in_as_plain_member
    privilege_keys.each { |key| grant_privileges(member, key) }
    sign_in_as_plain_member
  end
end
