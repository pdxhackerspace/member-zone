require 'test_helper'

class SlackUsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # ─── Index ─────────────────────────────────────────────────────────

  test 'index loads successfully' do
    get slack_users_path
    assert_response :success
  end

  # A rewrite of this page once left the old table in place below the import modals, so every
  # account rendered twice and the stale rows carried email addresses in their search text.
  test 'index renders each account exactly once' do
    get slack_users_path

    assert_response :success
    assert_select 'table', 1
    assert_select 'tr.slack-user-row', SlackUser.count
  end

  # The search input and the rows it hides have to share one live-filter element, or typing
  # filters nothing.
  test 'index search and rows sit under one live-filter controller' do
    get slack_users_path

    assert_response :success
    assert_select '[data-controller=?] input[data-live-filter-target=?]', 'live-filter', 'input'
    assert_select '[data-controller=?] tr[data-live-filter-target=?]', 'live-filter', 'item'
  end

  test 'index shows linked and unlinked counts' do
    get slack_users_path
    assert_response :success
    assert_match 'Linked', response.body
    assert_match 'Unlinked', response.body
  end

  test 'index does not show the email column' do
    get slack_users_path

    assert_response :success
    assert_select 'th', text: 'Email', count: 0
    assert_select 'a[href^=?]', 'mailto:', count: 0
  end

  test 'show masks email and raw attributes with reveal control' do
    slack_user = slack_users(:with_dept)

    get slack_user_path(slack_user)

    assert_response :success
    assert_select '[data-controller=?]', 'sensitive-reveal'
    assert_select '[data-action=?]', 'click->sensitive-reveal#toggle', text: /Show contact details/
    assert_select '[data-sensitive-reveal-target=?]', 'blurred', text: /with_dept@example\.com/
    assert_select 'pre[data-sensitive-reveal-target=?]', 'blurred', text: /department/
  end

  test 'index link modal can search members by email and username' do
    user = users(:one)

    get slack_users_path
    assert_response :success

    assert_select '.slack-link-user-item[data-user-id=?][data-user-email=?][data-username=?]',
                  user.id.to_s, user.email, user.username
  end

  test 'index status filters split active inactive and deactivated accounts' do
    recent = SlackUser.create!(slack_id: 'URECENTFILTER', display_name: 'Recent Slack', last_active_at: 1.month.ago)
    inactive = SlackUser.create!(slack_id: 'UINACTIVEFILTER', display_name: 'Dormant Slack', last_active_at: nil)
    deactivated = SlackUser.create!(slack_id: 'UDEACTIVATEDFILTER', display_name: 'Disabled Slack', deleted: true,
                                    last_active_at: 1.month.ago)

    get slack_users_path(status: 'active')
    assert_response :success
    assert_match recent.display_name, response.body
    assert_no_match inactive.display_name, response.body
    assert_no_match deactivated.display_name, response.body

    get slack_users_path(status: 'inactive')
    assert_response :success
    assert_match inactive.display_name, response.body
    assert_no_match recent.display_name, response.body
    assert_no_match deactivated.display_name, response.body
  end

  test 'apply_status_filter returns the requested status scope' do
    recent = SlackUser.create!(slack_id: 'URECENTHELPER', last_active_at: 1.month.ago)
    inactive = SlackUser.create!(slack_id: 'UINACTIVEHELPER', last_active_at: nil)
    deactivated = SlackUser.create!(slack_id: 'UDEACTIVATEDHELPER', deleted: true, last_active_at: 1.month.ago)
    scope = SlackUser.where(id: [recent.id, inactive.id, deactivated.id])

    assert_equal [recent.id], status_filter_ids(scope, 'active')
    assert_equal [inactive.id], status_filter_ids(scope, 'inactive')
    assert_equal [deactivated.id], status_filter_ids(scope, 'deactivated')
    assert_equal [recent.id, inactive.id, deactivated.id].sort, status_filter_ids(scope, 'unknown').sort
  end

  # ─── Link User ─────────────────────────────────────────────────────

  test 'link_user links slack user to a member' do
    slack_user = slack_users(:with_dept)
    user = users(:two)

    post link_user_slack_user_path(slack_user), params: { user_id: user.id }

    slack_user.reload
    assert_equal user.id, slack_user.user_id
  end

  test 'link_user does not copy slack profile data to member' do
    slack_user = slack_users(:with_dept)
    user = users(:two)
    user.update_columns(aliases: [], slack_id: nil, slack_handle: nil, avatar: nil)

    post link_user_slack_user_path(slack_user), params: { user_id: user.id }

    user.reload
    assert_empty user.aliases
    assert_nil user.slack_id
    assert_nil user.slack_handle
    assert_nil user.avatar
  end

  test 'link_user from index redirects back to index' do
    slack_user = slack_users(:with_dept)
    user = users(:two)

    post link_user_slack_user_path(slack_user), params: { user_id: user.id, from_index: 'true' }
    assert_redirected_to slack_users_path
  end

  test 'unlink_user disassociates slack user and clears matching member slack fields' do
    slack_user = slack_users(:with_dept)
    user = users(:two)
    user.update_columns(slack_id: slack_user.slack_id, slack_handle: slack_user.username)
    slack_user.update!(user: user)

    post unlink_user_slack_user_path(slack_user)

    assert_redirected_to slack_user_path(slack_user)
    assert_nil slack_user.reload.user_id
    user.reload
    assert_nil user.slack_id
    assert_nil user.slack_handle
  end

  # ─── Toggle Don't Link ─────────────────────────────────────────────

  test 'toggle_dont_link sets dont_link flag' do
    slack_user = slack_users(:with_dept)
    slack_user.update_columns(dont_link: false)

    post toggle_dont_link_slack_user_path(slack_user)

    slack_user.reload
    assert slack_user.dont_link?, 'dont_link should be set to true'
  end

  test 'toggle_dont_link unsets dont_link flag' do
    slack_user = slack_users(:with_dept)
    slack_user.update_columns(dont_link: true)

    post toggle_dont_link_slack_user_path(slack_user)

    slack_user.reload
    assert_not slack_user.dont_link?, 'dont_link should be set to false'
  end

  # ─── Create Member ─────────────────────────────────────────────────

  test 'create_member creates a new member from slack user' do
    slack_user = slack_users(:with_other_dept)
    slack_user.update_columns(user_id: nil)

    assert_difference 'User.count', 1 do
      post create_member_slack_user_path(slack_user)
    end

    slack_user.reload
    assert_not_nil slack_user.user_id

    new_user = User.find(slack_user.user_id)
    assert_equal 'Mary Jane', new_user.full_name
    assert_equal slack_user.email, new_user.email
    assert_equal slack_user.slack_id, new_user.slack_id
  end

  test 'create_member redirects to new member profile' do
    slack_user = slack_users(:with_other_dept)
    slack_user.update_columns(user_id: nil)

    post create_member_slack_user_path(slack_user)

    slack_user.reload
    new_user = User.find(slack_user.user_id)
    assert_redirected_to user_path(new_user)
  end

  # ─── Disabled Source Guards ──────────────────────────────────────

  test 'sync redirects with alert when slack source is disabled' do
    member_sources(:slack).update!(enabled: false)

    post sync_slack_users_path
    assert_redirected_to slack_users_path
    assert_equal 'Slack source is disabled.', flash[:alert]
  end

  test 'sync enqueues job without member updates by default' do
    assert_enqueued_with(job: Slack::UserSyncJob, args: [{ update_members: false }]) do
      post sync_slack_users_path
    end

    assert_redirected_to slack_users_path
    assert_equal 'Slack sync started. Matching members will be linked.', flash[:notice]
  end

  test 'sync enqueues job with member updates when switch is on' do
    assert_enqueued_with(job: Slack::UserSyncJob, args: [{ update_members: true }]) do
      post sync_slack_users_path, params: { update_members: '1' }
    end

    assert_redirected_to slack_users_path
    assert_match(/member accounts will be updated/, flash[:notice])
  end

  test 'index shows update member accounts switch with sync form' do
    get slack_users_path

    assert_response :success
    assert_select 'form[action=?][method=?]', sync_slack_users_path, 'post'
    assert_select '#slack_sync_update_members.form-check-input[role=?]', 'switch'
    assert_select 'input[type=?][value=?]', 'submit', 'Sync Slack users'
    assert_select 'button', text: 'Sync to Members', count: 0
  end

  # ─── Create Member ─────────────────────────────────────────────

  test 'create_member rejects already-linked slack user' do
    slack_user = slack_users(:with_dept)
    slack_user.update_columns(user_id: users(:one).id)

    assert_no_difference 'User.count' do
      post create_member_slack_user_path(slack_user)
    end

    assert_redirected_to slack_users_path
    follow_redirect!
    assert_match(/already linked/, response.body)
  end

  private

  def sign_in_as_local_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end

  def status_filter_ids(scope, status)
    controller = SlackUsersController.new
    controller.params = ActionController::Parameters.new(status: status)
    controller.send(:apply_status_filter, scope).pluck(:id)
  end
end
