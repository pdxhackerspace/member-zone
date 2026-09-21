require 'test_helper'

class ReminderSettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
    ReminderSetting.seed_defaults!
    MembershipSetting.instance.update!(use_builtin_membership_application: true)
    set_reminder_cadence('slack_signup', start_offset_days: 7, interval_days: 14, max_reminders: nil)
    set_reminder_cadence('application_link', start_offset_days: 3, interval_days: 3, max_reminders: 3)
    ReminderSetting.find_by!(key: 'application_link').update!(enabled: true)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'index lists slack signup reminder with preview counts' do
    get reminder_settings_url

    assert_response :success
    assert_match 'Slack signup reminder', response.body
    assert_match 'would be emailed today', response.body
    assert_match 'Application link reminder', response.body
    assert_match 'Orientation reminder', response.body
    assert_match 'Stale application reminder', response.body
    assert_select 'input[type=submit][value=Save]', count: 0
    assert_select 'form[data-controller=?]', 'reminder-setting-form'
    assert_select 'button', text: 'Send now', count: ReminderSetting::CATALOG.size
  end

  test 'index states each reminder cadence and offers the three fields that set it' do
    get reminder_settings_url

    assert_response :success
    assert_select 'input#reminder_start_offset_days_slack_signup[value=?]', '7'
    assert_select 'input#reminder_interval_days_slack_signup[value=?]', '14'
    assert_select 'input#reminder_max_reminders_slack_signup[value]', count: 0
    assert_match '7 days after approval, then every 14 days, with no limit', response.body
  end

  # Opting out is a member's choice about their own mail, and the staff reminder goes to
  # reviewers, so offering the switch there would only invite someone to set it.
  test 'index offers the opt-out switch only on reminders a member receives' do
    get reminder_settings_url

    assert_response :success
    assert_select 'input#reminder_allow_opt_out_orientation'
    assert_select 'input#reminder_allow_opt_out_staff_application', count: 0
  end

  # The one reminder whose last send is chosen by position rather than by date, so a blank
  # maximum quietly means the final notice never goes out.
  test 'index warns when parking has no maximum to end its sequence on' do
    set_reminder_cadence('parking_notices', max_reminders: nil)

    get reminder_settings_url

    assert_response :success
    assert_match 'the final notice never goes out', response.body
  end

  test 'update saves a reminder cadence' do
    patch reminder_setting_url('orientation'), params: {
      reminder_setting: { enabled: '1', start_offset_days: '-2', interval_days: '10', max_reminders: '4' }
    }

    assert_redirected_to reminder_settings_url
    orientation = ReminderSetting.find_by!(key: 'orientation')
    assert_equal(-2, orientation.start_offset_days)
    assert_equal 10, orientation.interval_days
    assert_equal 4, orientation.max_reminders
  end

  test 'update clears a maximum back to unlimited' do
    set_reminder_cadence('application_link', max_reminders: 3)

    patch reminder_setting_url('application_link'), params: {
      reminder_setting: { enabled: '1', max_reminders: '' }
    }

    assert_redirected_to reminder_settings_url
    assert ReminderSetting.find_by!(key: 'application_link').unlimited_reminders?
  end

  test 'update rejects an interval of zero' do
    set_reminder_cadence('orientation', interval_days: 14)

    patch reminder_setting_url('orientation'), params: {
      reminder_setting: { enabled: '1', interval_days: '0' }
    }

    assert_redirected_to reminder_settings_url
    assert_match(/not updated/i, flash[:alert])
    assert_equal 14, ReminderSetting.find_by!(key: 'orientation').interval_days
  end

  test 'index lists lapsed access reminder with preview counts' do
    get reminder_settings_url

    assert_response :success
    assert_match 'Lapsed member access reminder', response.body
    assert_match 'badged in during the window', response.body
  end

  test 'the overdue payment reminder page lays out the whole sequence including the lapse notice' do
    MembershipSetting.instance.update!(overdue_grace_period_days: 30)
    set_reminder_cadence('payment_overdue', start_offset_days: 5, interval_days: 7, max_reminders: nil)
    ReminderSetting.find_by!(key: 'payment_overdue').update!(enabled: true)
    lapsed_template = EmailTemplate.create!(
      key: 'membership_lapsed',
      name: 'Membership Lapsed',
      subject: 'Your dues have lapsed',
      body_html: '<p>Body</p>',
      body_text: 'Body',
      enabled: true
    )

    get reminder_setting_url('payment_overdue')

    assert_response :success
    assert_match 'What an overdue member hears, in order', response.body
    assert_match 'waiting out the start offset', response.body
    assert_match 'repeats every 7 days', response.body
    assert_select 'a[href=?]', email_template_path(lapsed_template), minimum: 1
    assert_match 'All three stages are governed by the Enabled switch', response.body
    assert_no_match(/no lapse notice when/, response.body)
  end

  # The reminder is off by default and now gates the lapse notice too, so the page has to say
  # that an overdue member is hearing nothing at all rather than just fewer reminders.
  test 'the overdue payment reminder page warns that a disabled reminder silences the lapse notice' do
    ReminderSetting.find_by!(key: 'payment_overdue').update!(enabled: false)

    get reminder_setting_url('payment_overdue')

    assert_response :success
    assert_select '.alert-warning', text: /no lapse notice when\s+they fall inactive/
  end

  test 'index offers a lookback window field only for reminders that scan a range' do
    ReminderSetting.find_by!(key: 'lapsed_access').update!(lookback_days: 4)

    get reminder_settings_url

    assert_response :success
    assert_select 'input#reminder_lookback_days_lapsed_access[value=?]', '4'
    assert_select 'input#reminder_lookback_days_payment_overdue', count: 0
  end

  test 'update changes the lapsed access lookback window' do
    reminder = ReminderSetting.find_by!(key: 'lapsed_access')

    patch reminder_setting_url('lapsed_access'), params: { reminder_setting: { lookback_days: '14' } }

    assert_redirected_to reminder_settings_url
    assert_equal 14, reminder.reload.lookback_days
  end

  test 'update rejects an out-of-range lookback window' do
    reminder = ReminderSetting.find_by!(key: 'lapsed_access')
    reminder.update!(lookback_days: 3)

    patch reminder_setting_url('lapsed_access'), params: { reminder_setting: { lookback_days: '0' } }

    assert_redirected_to reminder_settings_url
    assert_match(/not updated/i, flash[:alert])
    assert_equal 3, reminder.reload.lookback_days
  end

  test 'update ignores a lookback window on reminders that do not scan a range' do
    patch reminder_setting_url('payment_overdue'), params: {
      reminder_setting: { enabled: '1', lookback_days: '30' }
    }

    assert_redirected_to reminder_settings_url
    assert_equal 1, ReminderSetting.find_by!(key: 'payment_overdue').lookback_days
  end

  # A notice whose expiration moved is at reminder one, so the due list must not credit it
  # with the sends from the sequence that ended. Showing "4 of 4" beside somebody about to be
  # mailed again reads as a bug in the reminder.
  test 'show counts a restarted sequence from the start' do
    now = Time.zone.local(2026, 8, 6, 9, 0, 0)
    set_reminder_cadence('parking_notices', start_offset_days: -3, interval_days: 7, max_reminders: 4)
    ReminderSetting.find_by!(key: 'parking_notices').update!(enabled: true)
    owner = users(:one)
    notice = ParkingNotice.create!(
      user: owner, issued_by: owner, notice_type: 'permit', status: 'active',
      expires_at: now - 20.days, description: 'Restarted permit', location: 'Main Area'
    )
    ReminderDelivery.record!('parking_notices', notice, anchor: notice.expires_at, at: now - 8.days)
    ReminderDelivery.record!('parking_notices', notice, anchor: notice.expires_at, at: now - 1.day)
    notice.update!(expires_at: now + 1.day)

    travel_to now do
      get reminder_setting_url('parking_notices')
    end

    assert_response :success
    assert_select 'td.num', text: '0 of 4'
    assert_select 'td.num', text: '2 of 4', count: 0
  end

  # The count restarts with the sequence, but "Last reminder" is a fact about what we sent and
  # survives it. Lapsed access is where this bites: every new batch of visits is a new anchor,
  # so restart-filtering the timestamp would report Never for a member emailed yesterday.
  test 'show keeps the last reminder date across a restarted sequence' do
    now = Time.zone.local(2026, 8, 6, 8, 5, 0)
    ReminderSetting.find_by!(key: 'lapsed_access').update!(enabled: true, lookback_days: 1)
    user = User.create!(
      email: 'restarted-lapsed@example.com', full_name: 'Restarted Lapsed User', service_account: false,
      membership_state: 'inactive_member', payment_type: 'unknown', last_payment_date: (now - 30.days).to_date
    )
    user.update_columns(membership_state_entered_at: now - 45.days)
    # An earlier batch, already described and stamped, then a new visit that has not been.
    AccessLog.create!(user: user, logged_at: now - 40.hours, name: user.display_name,
                      lapsed_access_reminder_sent_at: now - 30.hours)
    AccessLog.create!(user: user, logged_at: now - 2.hours, name: user.display_name)
    record_reminder_sent('lapsed_access', user, at: now - 30.hours, anchor: now - 40.hours)

    travel_to now do
      get reminder_setting_url('lapsed_access')
    end

    assert_response :success
    assert_match user.display_name, response.body
    assert_select 'td span.profile-field-value.empty', text: 'Never', count: 0
    assert_select 'td span.profile-field-value', text: 'Yesterday'
  end

  test 'show lists due inactive members for lapsed access' do
    now = Time.zone.local(2026, 8, 6, 8, 5, 0)
    user = User.create!(
      email: 'due-lapsed-access@example.com',
      full_name: 'Due Lapsed Access User',
      service_account: false,
      membership_state: 'inactive_member',
      payment_type: 'unknown',
      last_payment_date: (now - 30.days).to_date
    )
    user.update_columns(membership_state_entered_at: now - 45.days)
    AccessLog.create!(user: user, logged_at: now - 1.hour, name: user.display_name, action: 'opened')

    travel_to now do
      get reminder_setting_url('lapsed_access')
    end

    assert_response :success
    assert_match user.display_name, response.body
  end

  test 'show counts the new visits behind each due member' do
    now = Time.zone.local(2026, 8, 6, 8, 5, 0)
    user = User.create!(
      email: 'repeat-visitor@example.com',
      full_name: 'Repeat Visitor',
      service_account: false,
      membership_state: 'inactive_member',
      payment_type: 'unknown',
      last_payment_date: (now - 30.days).to_date
    )
    user.update_columns(membership_state_entered_at: now - 45.days)
    3.times { |i| AccessLog.create!(user: user, logged_at: now - (i + 1).hours, name: user.display_name) }

    travel_to now do
      get reminder_setting_url('lapsed_access')
    end

    assert_response :success
    assert_select 'th', text: 'New visits'
    assert_select 'td.num', text: '3'
  end

  test 'show lists members waiting on their orientation' do
    now = Time.zone.local(2026, 8, 5, 7, 45, 0)
    set_reminder_cadence('orientation', start_offset_days: 14, interval_days: 14)
    MembershipSetting.instance.update!(
      new_member_expiry_days: 90,
      building_access_training_topic: training_topics(:building_access)
    )
    user = User.create!(
      email: 'awaiting-orientation-preview@example.com',
      full_name: 'Awaiting Orientation User',
      service_account: false,
      membership_state: 'new_member',
      payment_type: 'unknown'
    )
    user.update_columns(membership_state_entered_at: now - 20.days)
    MembershipApplication.create!(
      user: user,
      email: user.email,
      status: 'approved',
      reviewed_at: now - 20.days,
      submitted_at: now - 22.days
    )

    travel_to now do
      get reminder_setting_url('orientation')
    end

    assert_response :success
    assert_match 'Awaiting Orientation User', response.body
  end

  test 'show lists due members for slack signup' do
    now = Time.zone.local(2026, 8, 5, 7, 0, 0)
    user = User.create!(
      email: 'due-preview@example.com',
      full_name: 'Due Preview User',
      active: true,
      service_account: false,
      membership_state: 'current_member',
      payment_type: 'unknown'
    )
    MembershipApplication.create!(
      user: user,
      email: user.email,
      status: 'approved',
      reviewed_at: now - 10.days,
      submitted_at: now - 12.days
    )

    travel_to now do
      get reminder_setting_url('slack_signup')
    end

    assert_response :success
    assert_match 'Due Preview User', response.body
  end

  test 'show lists due verifications for application link' do
    now = Time.zone.local(2026, 8, 5, 7, 15, 0)
    verification = ApplicationVerification.create!(
      email: 'awaiting-application@example.com',
      confirmed_open_house: true,
      confirmed_code_of_conduct: true,
      created_at: now - 4.days,
      expires_at: now + 2.days
    )

    travel_to now do
      get reminder_setting_url('application_link')
    end

    assert_response :success
    assert_match verification.email, response.body
  end

  test 'show hides due verifications when application link reminder is disabled' do
    now = Time.zone.local(2026, 8, 5, 7, 15, 0)
    ReminderSetting.find_by!(key: 'application_link').update!(enabled: false)
    verification = ApplicationVerification.create!(
      email: 'disabled-show@example.com',
      confirmed_open_house: true,
      confirmed_code_of_conduct: true,
      created_at: now - 4.days,
      expires_at: now + 2.days
    )

    travel_to now do
      get reminder_setting_url('application_link')
    end

    assert_response :success
    assert_no_match verification.email, response.body
  end

  test 'show hides due verifications when builtin application is disabled' do
    now = Time.zone.local(2026, 8, 5, 7, 15, 0)
    MembershipSetting.instance.update!(use_builtin_membership_application: false)
    verification = ApplicationVerification.create!(
      email: 'builtin-off-show@example.com',
      confirmed_open_house: true,
      confirmed_code_of_conduct: true,
      created_at: now - 4.days,
      expires_at: now + 2.days
    )

    travel_to now do
      get reminder_setting_url('application_link')
    end

    assert_response :success
    assert_no_match verification.email, response.body
  end

  test 'update toggles reminder enabled state' do
    reminder = ReminderSetting.find_by!(key: 'slack_signup')
    reminder.update!(enabled: false)

    patch reminder_setting_url('slack_signup'), params: { reminder_setting: { enabled: '1' } }

    assert_redirected_to reminder_settings_url
    assert reminder.reload.enabled?
  end

  test 'index preserves admin allow_opt_out changes' do
    reminder = ReminderSetting.find_by!(key: 'payment_overdue')
    reminder.update!(allow_opt_out: false)

    get reminder_settings_url

    assert_response :success
    assert_not reminder.reload.allow_opt_out?
  end

  test 'send now runs slack signup reminder when enabled' do
    reminder = ReminderSetting.find_by!(key: 'slack_signup')
    reminder.update!(enabled: true)
    MemberSource.find_or_create_by!(key: 'slack') { |source| source.enabled = true }
    MemberSource.find_by!(key: 'slack').update!(enabled: true)

    post send_now_reminder_setting_url('slack_signup')

    assert_redirected_to reminder_settings_url
    assert_match(/run finished/i, flash[:notice])
  end

  test 'send now blocked when reminder disabled' do
    ReminderSetting.find_by!(key: 'slack_signup').update!(enabled: false)

    post send_now_reminder_setting_url('slack_signup')

    assert_redirected_to reminder_settings_url
    assert_match(/disabled/i, flash[:alert])
  end

  test 'index links every email template a reminder can send' do
    keys = ReminderSetting.find_by!(key: 'parking_notices').email_template_keys
    templates = keys.map { |key| create_template(key) }

    get reminder_settings_url

    assert_response :success
    assert_match 'Email templates:', response.body
    templates.each do |template|
      assert_select 'a[href=?]', email_template_path(template), text: template.name, minimum: 1
    end
  end

  test 'index labels a reminder with one template in the singular' do
    template = create_template('orientation_reminder')

    get reminder_settings_url

    assert_response :success
    assert_match 'Email template:', response.body
    assert_select 'a[href=?]', email_template_path(template), text: template.name, minimum: 1
  end

  test 'index warns when an enabled reminder points at a disabled template' do
    create_template('lapsed_access_reminder', enabled: false)
    ReminderSetting.find_by!(key: 'lapsed_access').update!(enabled: true)

    get reminder_settings_url

    assert_response :success
    assert_select 'span.badge.text-bg-warning-subtle', text: 'disabled'
  end

  test 'index mutes a disabled template when the reminder is off too' do
    create_template('lapsed_access_reminder', enabled: false)
    ReminderSetting.find_by!(key: 'lapsed_access').update!(enabled: false)

    get reminder_settings_url

    assert_response :success
    assert_select 'span.badge.text-bg-secondary-subtle', text: 'disabled'
    assert_select 'span.badge.text-bg-warning-subtle', text: 'disabled', count: 0
  end

  test 'index omits the template line for a reminder whose templates are missing' do
    EmailTemplate.where(key: ReminderSetting.catalog_email_template_keys).delete_all

    get reminder_settings_url

    assert_response :success
    assert_no_match 'Email template:', response.body
    assert_no_match 'Email templates:', response.body
  end

  test 'show links the email templates for the reminder' do
    template = create_template('lapsed_access_reminder')

    get reminder_setting_url('lapsed_access')

    assert_response :success
    assert_select 'a[href=?]', email_template_path(template), text: template.name
  end

  private

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end

  def create_template(key, enabled: true)
    EmailTemplate.create!(
      key: key,
      name: key.titleize,
      subject: "Subject for #{key}",
      body_html: '<p>Body</p>',
      body_text: 'Body',
      enabled: enabled
    )
  end
end
