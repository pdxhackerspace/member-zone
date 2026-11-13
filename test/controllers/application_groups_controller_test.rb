require 'test_helper'

class ApplicationGroupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @application = applications(:sample_app)
    @application_group = application_groups(:sample_group)
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'should get show' do
    get application_application_group_url(@application, @application_group)
    assert_response :success
  end

  test 'add member modal uses live-filter stimulus instead of DOMContentLoaded script' do
    get application_application_group_url(@application, @application_group)
    assert_response :success

    assert_select '#addUserModal[data-controller="live-filter"]'
    assert_select '#addUserModal[data-action*="live-filter#clear"]'
    assert_select '#userSearchInput[data-live-filter-target="input"][data-action*="live-filter#filter"]'
    assert_select '#addUserModal tr[data-live-filter-target="item"][data-search-text]'
    assert_select 'script', text: /DOMContentLoaded/, count: 0
    assert_select 'script', text: /userSearchInput/, count: 0
  end

  test 'add member modal search haystack includes username' do
    user = users(:three)
    get application_application_group_url(@application, @application_group)
    assert_response :success

    assert_select "#addUserModal tr[data-search-text*='#{user.username.downcase}']"
  end

  test 'add member modal live-filter works on turbo visit' do
    get application_application_group_url(@application, @application_group),
        headers: { 'Accept' => 'text/vnd.turbo-stream.html, text/html' }
    assert_response :success

    assert_select '#addUserModal[data-controller="live-filter"]'
    assert_select '#userSearchInput[data-action*="live-filter#filter"]'
  end

  test 'should get new' do
    get new_application_application_group_url(@application)
    assert_response :success
  end

  test 'should get edit' do
    get edit_application_application_group_url(@application, @application_group)
    assert_response :success
  end

  test 'should create application group with manual members' do
    assert_difference('ApplicationGroup.count', 1) do
      post application_application_groups_url(@application), params: {
        application_group: {
          name: 'New Manual Group',
          authentik_name: 'test:new-manual',
          member_source: 'manual'
        }
      }
    end
    group = ApplicationGroup.last
    assert_equal 'manual', group.member_source
    assert_redirected_to application_application_group_url(@application, group)
  end

  test 'should create application group with active members' do
    assert_difference('ApplicationGroup.count', 1) do
      post application_application_groups_url(@application), params: {
        application_group: {
          name: 'Active Group',
          authentik_name: 'test:active',
          member_source: 'active_members'
        }
      }
    end
    group = ApplicationGroup.last
    assert_equal 'active_members', group.member_source
  end

  test 'should create group syncing with another group via combined select' do
    assert_difference('ApplicationGroup.count', 1) do
      post application_application_groups_url(@application), params: {
        application_group: {
          name: 'Synced Group',
          authentik_name: 'test:synced',
          member_source: 'sync_group',
          sync_group_combined: "sync_group:#{@application_group.id}",
          sync_with_group_id: @application_group.id
        }
      }
    end
    group = ApplicationGroup.last
    assert_equal 'sync_group', group.member_source
    assert_equal @application_group.id, group.sync_with_group_id
  end

  test 'should resolve active_members from sync_group combined select' do
    assert_difference('ApplicationGroup.count', 1) do
      post application_application_groups_url(@application), params: {
        application_group: {
          name: 'Active via Sync',
          authentik_name: 'test:active-via-sync',
          member_source: 'sync_group',
          sync_group_combined: 'active_members'
        }
      }
    end
    group = ApplicationGroup.last
    assert_equal 'active_members', group.member_source
    assert_nil group.sync_with_group_id
  end

  test 'should update application group' do
    patch application_application_group_url(@application, @application_group), params: {
      application_group: { name: 'Updated Group', member_source: 'manual' }
    }
    assert_response :redirect
    @application_group.reload
    assert_equal 'Updated Group', @application_group.name
  end

  test 'should add user to manual group' do
    user = users(:one)
    post add_user_application_application_group_url(@application, @application_group), params: {
      user_id: user.id
    }
    assert_response :redirect
  end

  test 'should not add user to non-manual group' do
    @application_group.update!(member_source: 'active_members')
    user = users(:one)
    post add_user_application_application_group_url(@application, @application_group), params: {
      user_id: user.id
    }
    assert_response :redirect
    assert_match(/Cannot add members/, flash[:alert])
  end

  test 'should remove user' do
    user = users(:one)
    @application_group.users << user unless @application_group.users.include?(user)
    delete remove_user_application_application_group_url(@application, @application_group), params: {
      user_id: user.id
    }
    assert_response :redirect
  end

  # ─── Disabled Source Guards ──────────────────────────────────────

  test 'sync_to_authentik redirects with alert when member zone source is disabled' do
    member_sources(:member_zone).update!(enabled: false)

    post sync_to_authentik_application_application_group_path(@application, @application_group)
    assert_redirected_to application_application_group_path(@application, @application_group)
    assert_equal 'Member Zone source is disabled.', flash[:alert]
  end

  test 'sync picker splits core groups into sections' do
    system_app = Authentik::CoreGroupProvisioner.system_application
    system_app.application_groups.create!(
      name: 'Trusted admins', authentik_name: 'ctrlh:org:members:trusted-admins', member_source: 'manual'
    )
    system_app.application_groups.create!(
      name: 'Active Members', authentik_name: 'ctrlh:org:members:active', member_source: 'active_members'
    )

    get new_application_application_group_url(@application)

    assert_response :success
    assert_select 'optgroup[label=?]', 'Built-in core groups' do
      assert_select 'option', text: 'Active Members'
    end
    assert_select 'optgroup[label=?]', 'Custom core groups' do
      assert_select 'option', text: 'Trusted admins'
    end
    assert_select 'optgroup[label=?]', 'Other groups' do
      assert_select 'option', text: 'Sample Group (Sample Application)'
    end
  end

  test 'should not destroy a group other groups copy' do
    @application.application_groups.create!(
      name: 'Copy of sample',
      authentik_name: 'sample:copy',
      member_source: 'sync_group',
      sync_with_group: @application_group
    )

    assert_no_difference('ApplicationGroup.count') do
      delete application_application_group_url(@application, @application_group)
    end
    assert_redirected_to application_application_group_url(@application, @application_group)
    assert_match(/Used by Copy of sample \(Sample Application\)/, flash[:alert])
  end

  test 'should destroy application group' do
    assert_difference('ApplicationGroup.count', -1) do
      delete application_application_group_url(@application, @application_group)
    end
    assert_redirected_to application_url(@application)
  end

  private

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
