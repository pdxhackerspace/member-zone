require 'test_helper'

# The last of the administrator-only areas, converted to their own privileges: access logs,
# the three member sources, cash, the dashboard, incidents, the journal, the map,
# onboarding, parking, and reports.
#
# Each area gets the same pair — the holder reaches it, a plain member does not — plus, for
# every area that kept an action back, a test that the kept action still refuses the holder.
# Reparenting off AdminController un-gates every action that does not get a new filter, so
# those are the tests that would catch the mistake.
class PrivilegeRolloutPhase6Test < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @member = users(:one)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  DENIAL = 'You do not have access to that section.'.freeze

  # ─── One privilege opens one page ─────────────────────────────────────

  {
    'access.view_logs' => :access_logs_path,
    'sources.authentik.view' => :authentik_users_path,
    'sources.sheet.view' => :sheet_entries_path,
    'sources.slack.view' => :slack_users_path,
    'payments.manage_cash' => :cash_payments_path,
    'dashboard.admin' => :root_path,
    'incidents.manage' => :incident_reports_path,
    'journal.view' => :journals_path,
    'member_map.view' => :member_map_path,
    'onboarding.run' => :onboard_path,
    'parking.manage_notices' => :parking_notices_path,
    'reports.view' => :reports_path
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

  # ─── What each conversion held back ───────────────────────────────────

  # Reading a page and acting on what it lists are different grants everywhere here, so each
  # of these holds the read key and is refused the write.
  test 'access.view_logs does not import logs or link them to members' do
    holder('access.view_logs')

    post upload_access_logs_path
    assert_equal DENIAL, flash[:alert]

    post link_user_access_log_path(access_logs(:unlinked_entry))
    assert_equal DENIAL, flash[:alert]
  end

  test 'access.import_logs imports without being able to make a member' do
    holder('access.import_logs')

    post create_member_access_log_path(access_logs(:unlinked_entry))
    assert_equal DENIAL, flash[:alert]
  end

  test 'sources.slack.view does not sync, import, or create members' do
    holder('sources.slack.view')

    post sync_slack_users_path
    assert_equal DENIAL, flash[:alert]

    post import_members_slack_users_path
    assert_equal DENIAL, flash[:alert]

    post create_member_slack_user_path(slack_users(:with_dept))
    assert_equal DENIAL, flash[:alert]
  end

  test 'sources.sheet.view does not sync or reach the credential test' do
    holder('sources.sheet.view')

    post sync_sheet_entries_path
    assert_equal DENIAL, flash[:alert]

    get test_sheet_entries_path
    assert_equal DENIAL, flash[:alert]
  end

  # Pulling from Authentik and pushing to it are not the same risk: a bad pull is undone by
  # pulling again, a bad push has already changed the identity provider.
  test 'sources.authentik.sync pulls but does not push' do
    holder('sources.authentik.sync')

    post sync_authentik_users_path
    assert_not_equal DENIAL, flash[:alert]

    post push_to_authentik_authentik_user_path(phase6_authentik_user)
    assert_equal DENIAL, flash[:alert]
  end

  test 'reports.view reads reports but cannot edit a member from one' do
    holder('reports.view')

    post reports_update_user_path, params: { user_id: @member.id, action_type: 'deactivate' }

    assert_equal DENIAL, flash[:alert]
    assert_predicate @member.reload, :active?
  end

  test 'reports.edit_users edits from a report' do
    holder('reports.view', 'reports.edit_users')

    post reports_update_user_path, params: { user_id: @member.id, action_type: 'ban' }

    assert_not_equal DENIAL, flash[:alert]
    assert_predicate @member.reload, :banned?
  end

  test 'onboarding.run runs the wizard but does not approve the mail it queues' do
    holder('onboarding.run')

    post onboard_approve_all_mail_path(@member)

    assert_equal DENIAL, flash[:alert]
  end

  test 'onboarding.approve_mail approves without being able to start a wizard' do
    holder('onboarding.approve_mail')

    get onboard_path

    assert_response :redirect
    assert_equal DENIAL, flash[:alert]
  end

  # ─── Payments: sync, import/export and the processor test split apart ──

  test 'payments.view alone triggers no sync and no export' do
    holder('payments.view')

    post sync_paypal_payments_path
    assert_equal DENIAL, flash[:alert]

    get export_paypal_payments_path
    assert_equal DENIAL, flash[:alert]
  end

  test 'payments.sync syncs without being able to export the ledger' do
    holder('payments.view', 'payments.sync')

    get export_paypal_payments_path

    assert_equal DENIAL, flash[:alert]
  end

  test 'payments.import_export exports without being able to reach the processor test' do
    holder('payments.view', 'payments.import_export')

    get export_recharge_payments_path
    assert_not_equal DENIAL, flash[:alert]

    get test_recharge_payments_path
    assert_equal DENIAL, flash[:alert]
  end

  # ─── Mail: edit and AI rewrite are no longer administrator-only ────────

  test 'queued_mail.view reads the queue but does not edit a message' do
    holder('queued_mail.view')

    get edit_queued_mail_path(queued_mails(:pending_mail))

    assert_response :redirect
    assert_equal DENIAL, flash[:alert]
  end

  test 'queued_mail.edit opens a queued message for editing' do
    holder('queued_mail.view', 'queued_mail.edit')

    get edit_queued_mail_path(queued_mails(:pending_mail))

    assert_response :success
  end

  # approve_all sends the entire pending queue in one click, which is a different scale
  # from reviewing one message and has no key of its own.
  test 'queued_mail.approve does not reach the whole-queue actions' do
    holder('queued_mail.view', 'queued_mail.approve')

    post approve_all_queued_mails_path
    assert_equal DENIAL, flash[:alert]

    post reject_all_queued_mails_path
    assert_equal DENIAL, flash[:alert]
  end

  test 'email_templates.edit does not carry the AI rewrite with it' do
    holder('email_templates.view', 'email_templates.edit')

    get edit_email_template_path(phase6_template)
    assert_response :success
    assert_select "[data-action='email-template-rewrite#rewrite']", 0

    post rewrite_with_ai_email_template_path(phase6_template)
    assert_equal DENIAL, flash[:alert]
  end

  test 'email_templates.ai_rewrite adds the rewrite panel' do
    holder('email_templates.view', 'email_templates.edit', 'email_templates.ai_rewrite')

    get edit_email_template_path(phase6_template)

    assert_select "[data-action='email-template-rewrite#rewrite']", 1
  end

  test 'email_templates.edit does not seed or disable a template' do
    holder('email_templates.view', 'email_templates.edit')

    post seed_email_templates_path
    assert_equal DENIAL, flash[:alert]

    post toggle_email_template_path(phase6_template)
    assert_equal DENIAL, flash[:alert]
  end

  # ─── Access controllers: reading the roster is not exporting it ────────

  test 'access.manage_controller_types does not export the user file' do
    holder('access.manage_controller_types')

    get access_controller_types_path
    assert_response :success
    assert_select 'a[href=?]', export_users_access_controller_types_path, count: 0

    get export_users_access_controller_types_path
    assert_equal DENIAL, flash[:alert]
  end

  test 'access.export_users exports it' do
    holder('access.manage_controller_types', 'access.export_users')

    get access_controller_types_path
    assert_select 'a[href=?]', export_users_access_controller_types_path

    get export_users_access_controller_types_path
    assert_response :success
  end

  private

  def phase6_template
    @phase6_template ||= EmailTemplate.create!(
      key: 'phase6_template', name: 'Phase 6 Template', subject: 'Subject',
      body_html: '<p>Body</p>', body_text: 'Body', enabled: true
    )
  end

  def phase6_authentik_user
    @phase6_authentik_user ||= AuthentikUser.create!(authentik_id: 'phase6-authentik-user')
  end

  def holder(*privilege_keys)
    member = sign_in_as_plain_member
    privilege_keys.each { |key| grant_privileges(member, key) }
    sign_in_as_plain_member
  end
end
