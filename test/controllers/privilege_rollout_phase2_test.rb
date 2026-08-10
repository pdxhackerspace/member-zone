require 'test_helper'

# The privileges the seeded roles hand out, which until now were enforced nowhere: granting
# "Communications editor" conferred no access at all, and Front desk, Billing coordinator
# and Key fob manager each conferred less than they claimed.
#
# Each pair below is the contract: a holder gets in, a plain member does not. The companion
# file navigation_privileges_test.rb covers finding the page in the first place.
class PrivilegeRolloutPhase2Test < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # ─── Members ──────────────────────────────────────────────────────────

  test 'members.view_list opens the member directory' do
    holder('members.view_list')

    get users_path

    assert_response :success
  end

  test 'the member directory is refused without members.view_list' do
    sign_in_as_plain_member

    get users_path

    assert_response :redirect
  end

  test 'members.view_profile opens another member profile in the admin layout' do
    holder('members.view_profile')

    get user_path(users(:one), tab: :profile)

    assert_response :success
    assert_select '[data-tab-key]', minimum: 0
    assert_select 'ul.nav-tabs'
  end

  test 'members.edit_membership can open another member for editing' do
    holder('members.edit_membership')

    get edit_user_path(users(:one))

    assert_response :success
  end

  test 'editing another member is refused without the privilege' do
    sign_in_as_plain_member

    get edit_user_path(users(:one))

    assert_response :redirect
  end

  test 'members.edit_membership saves membership state' do
    member = users(:one)
    holder('members.edit_membership')

    patch user_path(member), params: { user: { membership_state: 'guest_member' } }

    assert_equal 'guest_member', member.reload.membership_state
  end

  # The permit list is the gate for fields, so a holder of the membership privilege must
  # not be able to hand themselves anything else through the same form.
  test 'members.edit_membership cannot set internal notes or admin' do
    member = users(:one)
    member.update!(notes: 'untouched')
    holder('members.edit_membership')

    patch user_path(member), params: { user: { notes: 'changed', is_admin: true } }

    assert_equal 'untouched', member.reload.notes
    assert_not_predicate member, :is_admin?
  end

  test 'members.edit_membership cannot ban through a membership state patch' do
    member = users(:one)
    member.update!(membership_state: 'current_member')
    holder('members.edit_membership')

    patch user_path(member), params: { user: { membership_state: 'banned_member' } }

    assert_equal 'current_member', member.reload.membership_state
  end

  test 'members.edit_membership cannot mark deceased through a membership state patch' do
    member = users(:one)
    member.update!(membership_state: 'current_member')
    holder('members.edit_membership')

    patch user_path(member), params: { user: { membership_state: 'deceased_member' } }

    assert_equal 'current_member', member.reload.membership_state
  end

  test 'members.edit_profile edit form shows contact fields but not notes or membership' do
    holder('members.edit_profile')

    get edit_user_path(users(:one))

    assert_response :success
    assert_select 'textarea[name="user[mailing_address]"]'
    assert_select 'input[name="user[phone_number]"]'
    assert_select 'input[name="user[aliases_text]"]'
    assert_select 'textarea[name="user[notes]"]', count: 0
    assert_select 'select[name="user[membership_status]"]', count: 0
  end

  test 'members.edit_notes edit form shows notes but not contact or membership fields' do
    holder('members.edit_notes')

    get edit_user_path(users(:one))

    assert_response :success
    assert_select 'textarea[name="user[notes]"]'
    assert_select 'textarea[name="user[mailing_address]"]', count: 0
    assert_select 'input[name="user[phone_number]"]', count: 0
    assert_select 'select[name="user[membership_status]"]', count: 0
  end

  # ─── Invitations ──────────────────────────────────────────────────────

  test 'invitations.view opens the invitation list' do
    holder('invitations.view')

    get invitations_path

    assert_response :success
  end

  test 'invitations.create opens the invitation form' do
    holder('invitations.create')

    get new_invitation_path

    assert_response :success
  end

  test 'the invitation list is refused without invitations.view' do
    sign_in_as_plain_member

    get invitations_path

    assert_response :redirect
  end

  # Front desk creates invitations but cannot see the mail queue; landing there would put
  # them straight into a denial.
  test 'creating an invitation lands somewhere the creator can open' do
    holder('invitations.create', 'invitations.view')

    post invitations_path, params: { invitation: { email: 'invitee@example.com', membership_type: 'member' } }

    assert_redirected_to invitations_path
  end

  test 'creating an invitation still lands on the queue for someone who can see it' do
    holder('invitations.create', 'queued_mail.view')

    post invitations_path, params: { invitation: { email: 'invitee2@example.com', membership_type: 'member' } }

    assert_redirected_to queued_mails_path
  end

  # ─── Payments ─────────────────────────────────────────────────────────

  test 'payments.view opens each payment list' do
    holder('payments.view')

    [paypal_payments_path, recharge_payments_path, kofi_payments_path].each do |path|
      get path
      assert_response :success, "#{path} should open for a payments.view holder"
    end
  end

  test 'payment lists are refused without payments.view' do
    sign_in_as_plain_member

    [paypal_payments_path, recharge_payments_path, kofi_payments_path].each do |path|
      get path
      assert_response :redirect, "#{path} should be refused without payments.view"
    end
  end

  test 'payments.view_events opens the payment event log' do
    holder('payments.view_events')

    get payment_events_path

    assert_response :success
  end

  # Phase 2 kept the whole cash ledger with administrators. Phase 6 split it: reading it is
  # part of seeing payments, recording one is its own key, because a cash payment moves a
  # member's dues status with no processor to reconcile against.
  test 'payments.view reads the cash ledger but cannot record one' do
    holder('payments.view', 'payments.link')

    get cash_payments_path
    assert_response :success

    get new_cash_payment_path
    assert_response :redirect
  end

  # ─── Communications ───────────────────────────────────────────────────

  test 'email_templates.view opens the template list' do
    holder('email_templates.view')

    get email_templates_path

    assert_response :success
  end

  test 'email_templates.edit opens a template for editing' do
    holder('email_templates.view', 'email_templates.edit')

    get edit_email_template_path(phase2_template)

    assert_response :success
  end

  test 'editing a template is refused with only the view privilege' do
    holder('email_templates.view')

    get edit_email_template_path(phase2_template)

    assert_response :redirect
  end

  test 'queued_mail.view opens the mail queue' do
    holder('queued_mail.view')

    get queued_mails_path

    assert_response :success
  end

  test 'the mail queue is refused without queued_mail.view' do
    sign_in_as_plain_member

    get queued_mails_path

    assert_response :redirect
  end

  test 'text_fragments.manage opens and edits fragments' do
    fragment = TextFragment.create!(key: 'phase2_fragment', title: 'Phase 2', content: 'before')
    holder('text_fragments.manage')

    get text_fragments_path
    assert_response :success

    patch text_fragment_path(fragment), params: { text_fragment: { content: 'after' } }
    assert_equal 'after', fragment.reload.content
  end

  # ─── Reparenting safety ───────────────────────────────────────────────
  #
  # Moving these controllers off AdminController un-gates every action that did not get a
  # new filter. Each of the following has no catalog key of its own and must stay refused.

  test 'a template holder cannot seed or toggle templates' do
    template = phase2_template
    holder('email_templates.view', 'email_templates.edit')

    post seed_email_templates_path
    assert_response :redirect

    assert_no_changes -> { template.reload.enabled? } do
      post toggle_email_template_path(template)
    end
  end

  test 'a mail queue holder cannot approve the whole queue or retry delivery' do
    holder('queued_mail.view', 'queued_mail.approve')

    post approve_all_queued_mails_path
    assert_response :redirect

    post reject_all_queued_mails_path
    assert_response :redirect
  end

  test 'a payments holder cannot sync, export or test the processor' do
    holder('payments.view', 'payments.link')

    post sync_paypal_payments_path
    assert_response :redirect

    get export_paypal_payments_path
    assert_response :redirect

    get test_recharge_payments_path
    assert_response :redirect
  end

  test 'a fragment holder cannot seed or bulk sync fragments' do
    holder('text_fragments.manage')

    post seed_text_fragments_path
    assert_response :redirect

    post sync_all_from_urls_text_fragments_path
    assert_response :redirect
  end

  test 'a directory holder cannot run the bulk Authentik syncs' do
    holder('members.view_list', 'members.view_profile')

    post sync_all_to_authentik_users_path
    assert_response :redirect

    post toggle_authentik_sync_inactive_as_active_users_path
    assert_response :redirect
  end

  test 'a directory holder cannot ban or delete a member' do
    member = users(:one)
    holder('members.view_list', 'members.view_profile', 'members.edit_membership')

    post ban_user_path(member)
    assert_response :redirect
    assert_not_equal 'banned', member.reload.membership_status

    assert_no_difference 'User.count' do
      delete user_path(member)
    end
  end

  private

  def phase2_template
    @phase2_template ||= EmailTemplate.create!(
      key: 'phase2_template', name: 'Phase 2 Template', subject: 'Subject',
      body_html: '<p>Body</p>', body_text: 'Body', enabled: true
    )
  end

  # Signs in a plain member holding exactly these privileges. Granting happens between two
  # sign-ins because User#conferred_privileges is memoized per instance.
  def holder(*privilege_keys)
    member = sign_in_as_plain_member
    privilege_keys.each { |key| grant_privileges(member, key) }
    sign_in_as_plain_member
  end
end
