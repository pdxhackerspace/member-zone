require 'test_helper'

class CoreGroupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'lists a custom core group that has never synced as needing attention' do
    group = create_core_group

    get default_settings_path

    assert_response :success
    assert_select 'h1', text: 'Core groups and Authentik naming'
    assert_select 'tr.row-attention', text: /Trusted admins/
    assert_select 'tr.row-attention', text: /Never synced/
    assert_select 'a[href=?]', default_settings_core_group_path(group)
  end

  test 'should get new' do
    get new_default_settings_core_group_path

    assert_response :success
    assert_select 'input[name=?]', 'core_group[name]'
    assert_select '#core_group_authentik_name[value=?]', "#{DefaultSetting.instance.members_prefix}:"
  end

  test 'should create a manual group on the system application' do
    assert_difference('ApplicationGroup.count', 1) do
      post default_settings_core_groups_path, params: {
        core_group: {
          name: 'Trusted admins',
          authentik_name: 'ctrlh:org:members:trusted-admins',
          note: 'People who can be trusted with the keys'
        }
      }
    end

    group = ApplicationGroup.order(:id).last
    assert_equal 'manual', group.member_source
    assert_equal 'Member Zone', group.application.name
    assert_equal 'People who can be trusted with the keys', group.note
    assert_redirected_to default_settings_core_group_path(group)
  end

  test 'should not create a core group without a name' do
    assert_no_difference('ApplicationGroup.count') do
      post default_settings_core_groups_path, params: {
        core_group: { name: '', authentik_name: 'ctrlh:org:members:blank' }
      }
    end

    assert_response :unprocessable_content
  end

  test 'should update a core group' do
    group = create_core_group

    patch default_settings_core_group_path(group), params: {
      core_group: { name: 'Board', authentik_name: group.authentik_name, note: 'The board' }
    }

    assert_redirected_to default_settings_core_group_path(group)
    assert_equal 'Board', group.reload.name
    assert_equal 'manual', group.member_source
  end

  test 'should add and remove a member' do
    group = create_core_group
    user = users(:one)

    post add_user_default_settings_core_group_path(group), params: { user_id: user.id }
    assert_redirected_to default_settings_core_group_path(group)
    assert_includes group.reload.users, user

    delete remove_user_default_settings_core_group_path(group), params: { user_id: user.id }
    assert_redirected_to default_settings_core_group_path(group)
    assert_not_includes group.reload.users, user
  end

  test 'should destroy a core group nothing copies' do
    group = create_core_group

    assert_difference('ApplicationGroup.count', -1) do
      delete default_settings_core_group_path(group)
    end
    assert_redirected_to default_settings_path
  end

  test 'should not destroy a core group other groups copy' do
    group = create_core_group
    ApplicationGroup.create!(
      application: applications(:sample_app),
      name: 'Wiki admins',
      authentik_name: 'sample:wiki-admins',
      member_source: 'sync_group',
      sync_with_group: group
    )

    assert_no_difference('ApplicationGroup.count') do
      delete default_settings_core_group_path(group)
    end
    assert_redirected_to default_settings_core_group_path(group)
    assert_match(/Used by Wiki admins \(Sample Application\)/, flash[:alert])
  end

  test 'does not manage an application group or a built-in core group' do
    get default_settings_core_group_path(application_groups(:sample_group))
    assert_response :not_found

    builtin = Authentik::CoreGroupProvisioner.system_application.application_groups.create!(
      name: 'Active Members', authentik_name: 'ctrlh:org:members:active', member_source: 'active_members'
    )
    get default_settings_core_group_path(builtin)
    assert_response :not_found
  end

  test 'member zone application links a custom group to its core group page' do
    group = create_core_group

    get application_path(group.application)

    assert_select 'a[href=?]', default_settings_core_group_path(group), text: group.name
  end

  test 'sync_to_authentik redirects when the member zone source is disabled' do
    group = create_core_group
    member_sources(:member_zone).update!(enabled: false)

    post sync_to_authentik_default_settings_core_group_path(group)

    assert_redirected_to default_settings_core_group_path(group)
    assert_equal 'Member Zone source is disabled.', flash[:alert]
  end

  test 'a member without the privilege is refused' do
    member = sign_in_as_plain_member

    get new_default_settings_core_group_path

    assert_redirected_to user_path(member)
  end

  test 'a member granted settings.defaults can open core groups' do
    member = sign_in_as_plain_member
    grant_privileges(member, 'settings.defaults')
    sign_in_as_plain_member

    get new_default_settings_core_group_path

    assert_response :success
  end

  test 'an administrator viewing as a member without the privilege is refused' do
    sign_in_as_admin
    post impersonate_user_path(users(:one).id)

    get default_settings_path

    assert_response :redirect
    assert_equal 'You do not have access to that section.', flash[:alert]
  end

  private

  def create_core_group
    Authentik::CoreGroupProvisioner.system_application.application_groups.create!(
      name: 'Trusted admins',
      authentik_name: 'ctrlh:org:members:trusted-admins',
      member_source: 'manual'
    )
  end
end
