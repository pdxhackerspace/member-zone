require 'test_helper'

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'shows user profile' do
    get user_path(@user)
    assert_response :success
    assert_match @user.display_name, response.body
  end

  test 'shows user with payment history on payments tab' do
    get user_path(@user, tab: :payments)
    assert_response :success
    assert_match @user.display_name, response.body
    assert_match(/Payment Events/i, response.body)
  end

  test 'admin profile tab links to linked membership applications' do
    app = MembershipApplication.create!(
      email: 'profile-link-test@example.com',
      user: @user,
      status: 'approved',
      submitted_at: 1.day.ago,
      reviewed_at: Time.current
    )

    get user_path(@user, tab: :profile)

    assert_response :success
    assert_select 'a[href=?]', membership_application_path(app), text: /Application ##{app.id}/
  end

  test 'admin profile uses shared member layout with admin actions' do
    get user_path(@user, tab: :profile)

    assert_response :success
    assert_select '.h-page-title', text: @user.display_name
    assert_select '.status-pill'
    assert_select '.dropdown-menu', text: /Ban/
    assert_select '.profile-section-header', text: /Identity/
    assert_select '.profile-section-header', text: /Training & access/
    assert_select '.profile-section-header', text: /System/
    assert_select '.card-membership', text: /Membership/
    assert_select '.override-banner', count: 0
  end

  test 'admin profile header shows username without email address' do
    @user.update!(username: 'privacyuser', email: 'privacy-header@example.com')

    get user_path(@user, tab: :profile)

    assert_response :success
    assert_select '.member-admin-identity-line', text: '@privacyuser'
    assert_select '.member-admin-identity-line', text: /privacy-header@example\.com/, count: 0
  end

  test 'admin profile masks contact details with reveal control' do
    @user.update!(
      email: 'masked-primary@example.com',
      extra_emails: ['masked-extra@example.com'],
      mailing_address: "123 Hidden Lane\nPortland, OR",
      phone_number: '555-987-6543'
    )

    get user_path(@user, tab: :profile)

    assert_response :success
    assert_select '[data-controller=?]', 'sensitive-reveal'
    assert_select '[data-action=?]', 'click->sensitive-reveal#toggle', text: /Show contact details/
    assert_select '[data-sensitive-reveal-target=?]', 'blurred', text: /masked-primary@example\.com/
    assert_select '[data-sensitive-reveal-target=?]', 'blurred', text: /masked-extra@example\.com/
    assert_select '[data-sensitive-reveal-target=?]', 'blurred', text: /123 Hidden Lane/
    assert_select '[data-sensitive-reveal-target=?]', 'blurred', text: /555-987-6543/
  end

  test 'admin can edit mailing address and phone number' do
    patch user_path(@user), params: {
      user: {
        mailing_address: "456 Admin Road\nPortland, OR",
        phone_number: '555-222-3333'
      }
    }

    assert_redirected_to user_path(@user)
    @user.reload
    assert_equal "456 Admin Road\nPortland, OR", @user.mailing_address
    assert_equal '555-222-3333', @user.phone_number
  end

  test 'member-facing profile does not show admin contact details' do
    member = users(:member_with_local_account)
    member.update!(
      mailing_address: "789 Member Secret\nPortland, OR",
      phone_number: '555-111-2222'
    )

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :profile)

    assert_response :success
    assert_no_match(/789 Member Secret/, response.body)
    assert_no_match(/555-111-2222/, response.body)
    assert_select '.profile-field-label', text: /Mailing address/, count: 0
    assert_select '.profile-field-label', text: /Phone number/, count: 0
  end

  test 'members cannot update admin-only contact details' do
    member = users(:member_with_local_account)
    member.update!(mailing_address: nil, phone_number: nil)

    delete logout_path
    sign_in_as_regular_member

    patch user_path(member), params: {
      user: {
        mailing_address: 'Should not save',
        phone_number: '555-000-0000'
      }
    }

    assert_redirected_to user_path(member)
    member.reload
    assert_nil member.mailing_address
    assert_nil member.phone_number
  end

  test 'admin profile shows active override banner only when override is active' do
    @user.update_columns(emergency_active_override: true, active: true, membership_state: 'overdue_member')

    get user_path(@user, tab: :profile)

    assert_response :success
    assert_select '.override-banner', text: /Active override applied/
    assert_select 'form[action=?]', clear_emergency_active_override_user_path(@user)
  end

  test 'admin preview hides admin-only profile affordances' do
    @user.update_columns(emergency_active_override: true, active: true, membership_state: 'overdue_member')

    get user_path(@user, view_as: :self, tab: :profile)

    assert_response :success
    assert_select '.preview-banner', text: /Previewing as/
    assert_select '.override-banner', count: 0
    assert_select '.dropdown-menu', text: /Ban/, count: 0
    assert_select '.profile-section-header', text: /System/, count: 0
    assert_no_match(/Disassociate/, response.body)
  end

  test 'member profile does not show membership application links' do
    member = users(:member_with_local_account)
    app = MembershipApplication.create!(
      email: 'member-hidden-app@example.com',
      user: member,
      status: 'approved',
      submitted_at: 1.day.ago,
      reviewed_at: Time.current
    )

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :profile)

    assert_response :success
    assert_select 'a[href=?]', membership_application_path(app), count: 0
  end

  test 'self messages tab badge only shows unread count' do
    member = users(:member_with_local_account)
    Message.where(recipient: member).destroy_all
    Message.create!(
      sender: users(:one),
      recipient: member,
      subject: 'Read message',
      body: 'Already read',
      read_at: Time.current
    )

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :dashboard)

    assert_response :success
    assert_select 'a.nav-link', text: /Messages\s*1/, count: 0
  end

  test 'admin user messages tab badge only shows unread count' do
    member = users(:member_with_local_account)
    Message.where(recipient: member).destroy_all
    Message.create!(
      sender: users(:one),
      recipient: member,
      subject: 'Read admin-visible message',
      body: 'Already read',
      read_at: Time.current
    )

    get user_path(member, tab: :profile)

    assert_response :success
    assert_select 'a.nav-link[href=?]', user_path(member, tab: :messages) do
      assert_select '.badge', count: 0
    end
  end

  test 'self messages tab badge shows unread count' do
    member = users(:member_with_local_account)
    Message.where(recipient: member).destroy_all
    Message.create!(
      sender: users(:one),
      recipient: member,
      subject: 'Unread message',
      body: 'Please read',
      read_at: nil
    )

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :dashboard)

    assert_response :success
    assert_select 'a.nav-link', text: /Messages\s*1/
  end

  test 'member dashboard disables view messages action when there are no messages' do
    member = users(:member_with_local_account)
    Message.where(recipient: member).destroy_all
    Message.where(sender: member).destroy_all

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :dashboard)

    assert_response :success
    assert_select 'a[href=?]', messages_path, count: 0
    assert_select '.action-card.disabled', text: /View messages/
  end

  test 'member dashboard enables view messages action for sent messages' do
    member = users(:member_with_local_account)
    Message.where(recipient: member).destroy_all
    Message.where(sender: member).destroy_all
    Message.create!(
      sender: member,
      recipient: users(:one),
      subject: 'Sent message',
      body: 'Already sent'
    )

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :dashboard)

    assert_response :success
    assert_select 'a[href=?]', messages_path(folder: :all), text: /View messages/
    assert_select '.action-card.disabled', count: 0
  end

  test 'member dashboard profile action opens setup wizard' do
    member = users(:member_with_local_account)

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :dashboard)

    assert_response :success
    assert_select 'a[href=?]', profile_setup_path, text: /Update your profile/
  end

  test 'member dashboard links to notification preferences' do
    member = users(:member_with_local_account)

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :dashboard)

    assert_response :success
    assert_select 'a.action-card[href=?]', notification_preferences_path, text: /Notifications/
    assert_select 'a[href=?]', notification_preferences_path, text: /Manage notifications/
    assert_select 'a.nav-link.active[href=?]', notification_preferences_path, count: 0
    assert_select 'a.nav-link[href=?]', notification_preferences_path, text: /Notifications/
  end

  test 'member profile tab links to notification preferences' do
    member = users(:member_with_local_account)

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :profile)

    assert_response :success
    assert_select 'a[href=?]', notification_preferences_path, text: /Manage/
  end

  test 'member dashboard shows train a member action for trainers' do
    delete logout_path
    trainer = sign_in_as_trainer
    TrainerCapability.create!(user: trainer, training_topic: training_topics(:laser_cutting))

    get user_path(trainer, tab: :dashboard)

    assert_response :success
    assert_select 'a[href=?]', train_member_path, text: /Train a member/
  end

  test 'member dashboard hides train a member action for non-trainers' do
    member = users(:member_with_local_account)

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :dashboard)

    assert_response :success
    assert_select 'a[href=?]', train_member_path, count: 0
  end

  test 'self profile hides inline edit actions and sessions field' do
    member = users(:member_with_local_account)

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :profile)

    assert_response :success
    assert_select '.profile-field-edit', count: 0
    assert_no_match(/Sessions/, response.body)
  end

  test 'self profile shows the same member resources as dashboard' do
    member = users(:member_with_local_account)
    topic = training_topics(:laser_cutting)
    Training.create!(trainee: member, trainer: users(:one), training_topic: topic, trained_at: Time.current)

    delete logout_path
    sign_in_as_regular_member

    get user_path(member, tab: :dashboard)

    assert_response :success
    assert_select '.sidebar-card', text: /Resources for you/
    assert_select 'a.resource-link[href=?]', 'https://example.com/laser-safety', text: /Laser Safety Guide/

    get user_path(member, tab: :profile)

    assert_response :success
    assert_select '.sidebar-card', text: /Resources for you/
    assert_select 'a.resource-link[href=?]', 'https://example.com/laser-safety', text: /Laser Safety Guide/
  end

  # ─── Disabled Source Guards ──────────────────────────────────────

  test 'sync from authentik redirects with alert when authentik source is disabled' do
    member_sources(:authentik).update!(enabled: false)

    post sync_users_path
    assert_redirected_to users_path
    assert_equal 'Authentik source is disabled.', flash[:alert]
  end

  test 'sync to authentik redirects with alert when member zone source is disabled' do
    member_sources(:member_zone).update!(enabled: false)

    post sync_all_to_authentik_users_path
    assert_redirected_to users_path
    assert_equal 'Member Zone source is disabled.', flash[:alert]
  end

  test 'per-user sync_to_authentik redirects with alert when member zone source is disabled' do
    member_sources(:member_zone).update!(enabled: false)

    post sync_to_authentik_user_path(@user)
    assert_redirected_to user_path(@user)
    assert_equal 'Member Zone source is disabled.', flash[:alert]
  end

  test 'toggle_authentik_sync_inactive_as_active flips the setting, flags inactive members, and syncs' do
    DefaultSetting.instance.update!(authentik_sync_inactive_as_active: true)
    inactive = users(:one)
    inactive.update_columns(active: false, authentik_dirty: false)

    assert_enqueued_with(job: Authentik::FullSyncToAuthentikJob) do
      post toggle_authentik_sync_inactive_as_active_users_path
    end

    assert_redirected_to users_path
    assert_not DefaultSetting.instance.authentik_sync_inactive_as_active
    assert inactive.reload.authentik_dirty, 'inactive member with an Authentik ID should be flagged for re-sync'
  end

  test 'toggle_authentik_sync_inactive_as_active does not flag active members for re-sync' do
    active_member = users(:two)
    active_member.update_columns(active: true, authentik_dirty: false)

    post toggle_authentik_sync_inactive_as_active_users_path

    assert_redirected_to users_path
    assert_not active_member.reload.authentik_dirty, 'active members should not be flagged by the toggle'
  end

  test 'per-user sync_from_authentik redirects with alert when authentik source is disabled' do
    member_sources(:authentik).update!(enabled: false)

    post sync_from_authentik_user_path(@user)
    assert_redirected_to user_path(@user)
    assert_equal 'Authentik source is disabled.', flash[:alert]
  end

  test 'unlink_slack disassociates linked slack account from member page' do
    slack_user = slack_users(:with_dept)
    @user.update_columns(slack_id: slack_user.slack_id, slack_handle: slack_user.username)
    slack_user.update!(user: @user)

    post unlink_slack_user_path(@user)

    assert_redirected_to user_path(@user, tab: :profile)
    assert_nil slack_user.reload.user_id
    @user.reload
    assert_nil @user.slack_id
    assert_nil @user.slack_handle
  end

  test 'unlink_authentik disassociates linked authentik account from member page' do
    authentik_user = AuthentikUser.create!(
      authentik_id: @user.authentik_id,
      username: 'auth-user',
      email: 'auth@example.com',
      full_name: 'Auth User',
      user: @user
    )

    post unlink_authentik_user_path(@user)

    assert_redirected_to user_path(@user, tab: :profile)
    assert_nil authentik_user.reload.user_id
    assert_nil @user.reload.authentik_id
    assert_not @user.authentik_dirty?
  end

  test 'unlink_sheet disassociates linked sheet entry from member page' do
    sheet_entry = sheet_entries(:member_list_entry)
    sheet_entry.update!(user: @user)

    post unlink_sheet_user_path(@user)

    assert_redirected_to user_path(@user, tab: :profile)
    assert_nil sheet_entry.reload.user_id
  end

  test 'create with duplicate email shows link to existing member profile' do
    post users_path, params: {
      user: {
        full_name: 'Duplicate Email Test',
        email: @user.email
      }
    }

    assert_response :unprocessable_content
    assert_select '.alert', text: /Unable to create member: email is already in use by/
    assert_select ".alert a[href='#{user_path(@user)}']", text: @user.display_name
  end

  test 'live search is rendered as server search without retaining pagination' do
    get users_path(page: 2, q: 'pagination target')

    assert_response :success
    assert_select 'form[action=?][method=get][data-turbo-frame=?]', users_path, 'users_results' do
      assert_select 'input[name=q][value=?]', 'pagination target'
      assert_select 'input[name=page]', count: 0
    end
    assert_select 'turbo-frame[id=?]', 'users_results'
  end

  test 'member search paginates the filtered result set' do
    105.times do |index|
      User.create!(
        authentik_id: "pagination-filler-#{index}",
        full_name: "Pagination Filler #{index.to_s.rjust(3, '0')}",
        username: "paginationfiller#{index}",
        email: "pagination-filler-#{index}@example.com",
        active: true
      )
    end
    target = User.create!(
      authentik_id: 'pagination-target',
      full_name: 'Zzz Live Search Pagination Target',
      username: 'livesearchpaginationtarget',
      email: 'live-search-pagination-target@example.com',
      active: true
    )
    target.update_columns(created_at: 2.weeks.ago, updated_at: 2.weeks.ago)

    get users_path
    assert_response :success
    assert_no_match target.full_name, response.body

    get users_path(q: 'Live Search Pagination Target')
    assert_response :success
    assert_match target.full_name, response.body
  end

  test 'pause_key_access pauses the member and redirects to profile' do
    assert_not @user.key_access_paused?

    post pause_key_access_user_path(@user)

    assert_redirected_to user_path(@user, tab: :profile)
    assert @user.reload.key_access_paused?
    follow_redirect!
    assert_match(/Key access paused/i, response.body)
  end

  test 'resume_key_access resumes the member and redirects to profile' do
    @user.pause_key_access!

    post resume_key_access_user_path(@user)

    assert_redirected_to user_path(@user, tab: :profile)
    assert_not @user.reload.key_access_paused?
    follow_redirect!
    assert_match(/Key access resumed/i, response.body)
  end

  test 'pause_key_access redirects to the add key screen when return_to=add_key' do
    post pause_key_access_user_path(@user, return_to: 'add_key')

    assert_redirected_to new_rfid_path(rfid: { user_id: @user.id })
    assert @user.reload.key_access_paused?
  end

  test 'pause_key_access is idempotent when already paused' do
    @user.pause_key_access!

    post pause_key_access_user_path(@user)

    assert_redirected_to user_path(@user, tab: :profile)
    follow_redirect!
    assert_match(/already paused/i, response.body)
  end

  test 'admin profile shows pause access button and paused state' do
    get user_path(@user, tab: :profile)
    assert_response :success
    assert_select 'form[action=?]', pause_key_access_user_path(@user)

    @user.pause_key_access!
    get user_path(@user, tab: :profile)
    assert_response :success
    assert_select 'form[action=?]', resume_key_access_user_path(@user)
    assert_match(/Access paused/i, response.body)
  end

  test 'admin parking tab shows print actions for permits and tickets' do
    printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')
    permit = parking_notices(:active_permit)
    ticket = ParkingNotice.create!(
      notice_type: 'ticket', status: 'active', user: @user, issued_by: @user,
      expires_at: 3.days.from_now, description: 'Ticket on member profile', location: 'Main Area'
    )

    get user_path(@user, tab: :parking)

    assert_response :success
    assert_select 'a[href=?]', print_notice_parking_notice_path(permit, printer_id: printer.id)
    assert_select 'a[href=?]', print_notice_parking_notice_path(ticket, printer_id: printer.id)
  end

  test 'member parking tab shows print for permits but not tickets' do
    sign_in_as_regular_member
    member = User.find_by!(authentik_id: "local:#{local_accounts(:regular_member).id}")
    printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')
    permit = member.parking_notices.create!(
      notice_type: 'permit', status: 'active', issued_by: member,
      expires_at: 3.days.from_now, description: 'Member permit', location: 'Woodshop'
    )
    ticket = ParkingNotice.create!(
      notice_type: 'ticket', status: 'active', user: member, issued_by: users(:one),
      expires_at: 3.days.from_now, description: 'Member ticket', location: 'Main Area'
    )

    get user_path(member, tab: :parking)

    assert_response :success
    assert_select 'a[href=?]', print_notice_member_parking_permit_path(permit, printer_id: printer.id)
    assert_select 'a[href=?]', print_notice_member_parking_permit_path(ticket, printer_id: printer.id), count: 0
  end

  test 'member parking tab defaults to active notices only, with filter pills' do
    sign_in_as_regular_member
    member = User.find_by!(authentik_id: "local:#{local_accounts(:regular_member).id}")
    create_member_parking_notices(member)

    get user_path(member, tab: :parking)

    assert_response :success
    assert_select '.filter-chip', 3
    assert_match 'Active woodshop permit', response.body
    assert_no_match 'Expired lot ticket', response.body
    assert_no_match 'Cleared laser permit', response.body
  end

  test 'member parking tab filters stack' do
    sign_in_as_regular_member
    member = User.find_by!(authentik_id: "local:#{local_accounts(:regular_member).id}")
    create_member_parking_notices(member)

    get user_path(member, tab: :parking, statuses: 'active,expired')

    assert_response :success
    assert_match 'Active woodshop permit', response.body
    assert_match 'Expired lot ticket', response.body
    assert_no_match 'Cleared laser permit', response.body
  end

  test 'member parking tab shows everything when filters are cleared' do
    sign_in_as_regular_member
    member = User.find_by!(authentik_id: "local:#{local_accounts(:regular_member).id}")
    create_member_parking_notices(member)

    get user_path(member, tab: :parking, statuses: 'all')

    assert_response :success
    assert_match 'Active woodshop permit', response.body
    assert_match 'Expired lot ticket', response.body
    assert_match 'Cleared laser permit', response.body
  end

  test 'member parking tab shows a clear action for expired tickets but no print action' do
    sign_in_as_regular_member
    member = User.find_by!(authentik_id: "local:#{local_accounts(:regular_member).id}")
    Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')
    expired = ParkingNotice.create!(
      notice_type: 'ticket', status: 'expired', user: member, issued_by: users(:one),
      expires_at: 2.days.ago, description: 'Expired lot ticket', location: 'Parking Lot'
    )

    get user_path(member, tab: :parking, statuses: 'expired')

    assert_response :success
    assert_select 'form[action^=?]', close_member_parking_permit_path(expired)
    assert_select 'a[href^=?]', print_notice_member_parking_permit_path(expired), count: 0
  end

  private

  def sign_in_as_local_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: {
        email: account.email,
        password: 'localpassword123'
      }
    }
  end

  def sign_in_as_regular_member
    account = local_accounts(:regular_member)
    post local_login_path, params: {
      session: {
        email: account.email,
        password: 'memberpassword123'
      }
    }
  end

  def sign_in_as_trainer
    account = local_accounts(:trainer_account)
    post local_login_path, params: {
      session: {
        email: account.email,
        password: 'trainerpassword123'
      }
    }
    User.find_by!(authentik_id: "local:#{account.id}")
  end

  # One notice in each status for exercising the member parking tab filters.
  def create_member_parking_notices(member)
    member.parking_notices.create!(
      notice_type: 'permit', status: 'active', issued_by: member,
      expires_at: 3.days.from_now, description: 'Active woodshop permit', location: 'Woodshop'
    )
    ParkingNotice.create!(
      notice_type: 'ticket', status: 'expired', user: member, issued_by: users(:one),
      expires_at: 2.days.ago, description: 'Expired lot ticket', location: 'Parking Lot'
    )
    member.parking_notices.create!(
      notice_type: 'permit', status: 'cleared', issued_by: member,
      expires_at: 10.days.ago, cleared_at: 8.days.ago, cleared_by: member,
      description: 'Cleared laser permit', location: 'Main Area'
    )
  end
end
