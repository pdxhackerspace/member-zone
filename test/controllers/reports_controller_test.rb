require 'test_helper'

class ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_admin
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'index lists every report' do
    get reports_url

    assert_response :success
    Reports::Catalog.reports.each do |report|
      assert_match report.title, response.body, "#{report.key} missing from the report index"
    end
  end

  test 'every report in the catalog renders' do
    Reports::Catalog.reports.each do |report|
      get report_url(report.key)
      assert_response :success, "#{report.key} did not render"
    end
  end

  test 'a report with rows renders its table and inline actions' do
    users(:one).update_columns(membership_state: 'unknown', legacy: true, service_account: false)

    get report_url('membership-status-unknown')

    assert_response :success
    assert_match users(:one).display_name, response.body
    # The action buttons post back to the report they were used from.
    assert_match 'name="anchor" id="anchor" value="membership-status-unknown"', response.body
  end

  # Nobody is billing a sponsored member on purpose, so they are not a data problem.
  test 'payment type unknown leaves sponsored members out' do
    sponsored = users(:one)
    sponsored.update_columns(payment_type: 'unknown', active: true, service_account: false)
    sponsored.update!(membership_state: 'sponsored_member', is_sponsored: true)

    get report_url('payment-type-unknown')

    assert_response :success
    assert_equal 'sponsored', sponsored.reload.payment_type
    assert_no_match sponsored.display_name, response.body
  end

  test 'payment type unknown says whether the member can get into the building' do
    member = users(:one)
    member.update_columns(payment_type: 'unknown', active: true, service_account: false)
    Rfid.create!(user: member, rfid: 'REPORT001')

    get report_url('payment-type-unknown')

    assert_response :success
    assert_match member.display_name, response.body
    assert_match 'Building access', response.body
    assert_match 'Key, not trained', response.body
  end

  test 'payment type unknown shows when building access training happened' do
    member = User.create!(authentik_id: "ptu-#{SecureRandom.hex(4)}", full_name: 'Trained No Key',
                          payment_type: 'unknown', membership_state: 'current_member', active: true)
    topic = training_topics(:building_access)
    MembershipSetting.instance.update!(building_access_training_topic: topic)
    Training.create!(trainee: member, training_topic: topic, trained_at: Time.zone.local(2024, 3, 15, 10, 0))

    get report_url('payment-type-unknown')

    assert_response :success
    assert_match member.display_name, response.body
    assert_match 'Trained, no key', response.body
    assert_match 'Mar 15, 2024', response.body
  end

  test 'charts render' do
    get reports_charts_url
    assert_response :success
  end

  test 'an unknown report key redirects instead of raising' do
    get report_url('not-a-report')

    assert_redirected_to reports_path
    assert_equal 'Unknown report.', flash[:alert]
  end

  test 'the pre-reorganization view-all urls redirect to the report' do
    get '/reports/dues-status-lapsed/all'
    assert_redirected_to '/reports/dues-status-lapsed'
  end

  test 'active members with no slack lists only active members lacking a linked slack account' do
    linked = users(:one)
    slack_users(:with_dept).update!(user: linked)

    unlinked = users(:two)

    inactive = User.create!(authentik_id: 'authentik-no-slack-inactive', full_name: 'Inactive No Slack')
    service = User.create!(authentik_id: 'authentik-no-slack-service', full_name: 'Service No Slack',
                           service_account: true, active: true)

    assert_not inactive.reload.active?
    assert service.reload.active?

    get report_url('active-no-slack')

    assert_response :success
    assert_match unlinked.display_name, response.body
    assert_no_match(/#{Regexp.escape(linked.display_name)}/, response.body)
    assert_no_match(/#{Regexp.escape(inactive.display_name)}/, response.body)
    assert_no_match(/#{Regexp.escape(service.display_name)}/, response.body)
  end

  test 'active members with no slack excludes members who joined before the account age limit' do
    MembershipSetting.instance.update!(slack_signup_reminder_max_account_age_months: 6)

    recent = User.create!(
      authentik_id: 'authentik-no-slack-recent',
      full_name: 'Recent No Slack',
      email: 'recent-no-slack@example.com',
      membership_state: 'current_member',
      created_at: 2.months.ago
    )
    old = User.create!(
      authentik_id: 'authentik-no-slack-old',
      full_name: 'Old No Slack',
      email: 'old-no-slack@example.com',
      membership_state: 'current_member',
      created_at: 8.months.ago
    )

    get report_url('active-no-slack')

    assert_response :success
    assert_match recent.display_name, response.body
    assert_no_match(/#{Regexp.escape(old.display_name)}/, response.body)
  end

  test 'lapsed members with access counts only badge-ins after the last payment' do
    user = lapsed_member('authentik-lapsed-access', Date.new(2025, 1, 15))

    AccessLog.create!(user: user, logged_at: Time.zone.local(2025, 1, 10, 9, 0), name: 'before')
    AccessLog.create!(user: user, logged_at: Time.zone.local(2025, 2, 1, 9, 0), name: 'after')
    AccessLog.create!(user: user, logged_at: Time.zone.local(2025, 3, 1, 9, 0), name: 'later')

    entries = Reports::LapsedWithAccessQuery.new.entries

    assert_equal 2, entries.dig(user.id, :access_count)
    assert_equal Date.new(2025, 1, 15), entries.dig(user.id, :last_payment_date)
    assert_equal Time.zone.local(2025, 3, 1, 9, 0), entries.dig(user.id, :most_recent_at)
  end

  test 'a payment recorded outside the users table still moves the cutoff' do
    user = lapsed_member('authentik-lapsed-paypal', Date.new(2025, 1, 15))
    PaypalPayment.create!(paypal_id: 'txn-lapsed-cutoff', user: user, amount: 40,
                          transaction_time: Time.zone.local(2025, 2, 10, 12, 0))

    AccessLog.create!(user: user, logged_at: Time.zone.local(2025, 2, 1, 9, 0), name: 'before paypal')
    AccessLog.create!(user: user, logged_at: Time.zone.local(2025, 3, 1, 9, 0), name: 'after paypal')

    entries = Reports::LapsedWithAccessQuery.new.entries

    assert_equal 1, entries.dig(user.id, :access_count)
    assert_equal Date.new(2025, 2, 10), entries.dig(user.id, :last_payment_date)
  end

  test 'a badge-in exactly on the last payment cutoff does not count as access since lapsing' do
    user = lapsed_member('authentik-lapsed-boundary', Date.new(2025, 1, 15))
    AccessLog.create!(user: user, logged_at: Date.new(2025, 1, 15).end_of_day, name: 'on the cutoff')

    assert_not_includes Reports::LapsedWithAccessQuery.new.entries.keys, user.id
  end

  test 'a badge-in exactly on the one-year cutoff still counts as recent' do
    user = User.create!(authentik_id: 'authentik-legacy-boundary', full_name: 'Legacy Boundary', legacy: true)
    query = Reports::LegacyAccessQuery.new(since: 1.year.ago, recent_access_limit: 10)
    AccessLog.create!(user: user, logged_at: query.send(:cutoffs).fetch(user.id), name: 'on the cutoff')

    assert_equal 1, query.entries.dig(user.id, :access_count)
  end

  test 'lapsed members with no badge-in since their last payment are excluded' do
    user = lapsed_member('authentik-lapsed-quiet', Date.new(2025, 6, 1))
    AccessLog.create!(user: user, logged_at: Time.zone.local(2025, 5, 1, 9, 0), name: 'before only')

    assert_not_includes Reports::LapsedWithAccessQuery.new.entries.keys, user.id
  end

  test 'awaiting orientation lists approved members with no building access training' do
    MembershipSetting.instance.update!(building_access_training_topic: training_topics(:building_access))
    waiting = new_member('authentik-awaiting-orientation', approved_at: Time.zone.local(2026, 4, 27, 10, 0))
    oriented = new_member('authentik-oriented')
    Training.create!(trainee: oriented, training_topic: training_topics(:building_access), trained_at: 1.day.ago)

    get report_url('awaiting-orientation')

    assert_response :success
    assert_match waiting.display_name, response.body
    assert_no_match(/#{Regexp.escape(oriented.display_name)}/, response.body)
    assert_match 'Apr 27', response.body
  end

  test 'awaiting orientation says so when a member never had an application' do
    MembershipSetting.instance.update!(building_access_training_topic: training_topics(:building_access))
    onboarded = new_member('authentik-no-application')

    get report_url('awaiting-orientation')

    assert_response :success
    assert_match onboarded.display_name, response.body
    assert_match 'No application', response.body
  end

  # Somebody who was never let into the building is not a billing problem yet.
  test 'dues lapsed leaves out members still waiting on their orientation' do
    MembershipSetting.instance.update!(building_access_training_topic: training_topics(:building_access))
    trained = overdue_member('authentik-overdue-trained', approved_at: Time.zone.local(2026, 4, 27, 10, 0))
    Training.create!(trainee: trained, training_topic: training_topics(:building_access), trained_at: 30.days.ago)
    untrained = overdue_member('authentik-overdue-untrained')

    get report_url('dues-status-lapsed')

    assert_response :success
    assert_match trained.display_name, response.body
    assert_no_match(/#{Regexp.escape(untrained.display_name)}/, response.body)
    assert_match 'Apr 27', response.body
  end

  test 'report counts match the number of rows each report returns' do
    counts = Reports::Catalog.counts

    Reports::Catalog.reports.each do |report|
      assert_equal report.build_query.relation.count, counts[report.key], "#{report.key} count disagrees with its rows"
    end
  end

  # Each build_query returns a fresh, separately-memoizing object, so asking for one
  # twice repeats the report's whole aggregate. Rendering a report used to build three:
  # one for the sidebar count, one for the rows, one for the page locals.
  test 'showing a report runs its expensive aggregate only once' do
    user = lapsed_member('authentik-aggregate-once', Date.new(2025, 1, 15))
    AccessLog.create!(user: user, logged_at: Time.zone.local(2025, 2, 1, 9, 0), name: 'after')

    rollups = 0
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      rollups += 1 if payload[:sql].to_s.include?('AS access_count')
    end

    begin
      get report_url('lapsed-with-access')
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_response :success
    assert_equal 1, rollups
  end

  test 'sidebar counts skip the report being rendered, which works its own out' do
    counts = Reports::Catalog.counts(except: 'dues-status-lapsed')

    assert_not counts.key?('dues-status-lapsed')
    assert_equal Reports::Catalog.reports.size - 1, counts.size
  end

  test 'update_user returns to the report it was invoked from' do
    user = users(:one)

    post reports_update_user_path, params: {
      user_id: user.id, action_type: 'paying', anchor: 'dues-status-lapsed'
    }

    assert_redirected_to report_path('dues-status-lapsed')
    assert_equal 'current_member', user.reload.membership_state
  end

  private

  # A member with lapsed dues and no payment history beyond the date given, so the
  # cutoff under test is not moved by fixture payments.
  def lapsed_member(authentik_id, last_payment_on)
    User.create!(authentik_id: authentik_id, full_name: "Lapsed #{authentik_id}",
                 membership_state: 'inactive_member', last_payment_date: last_payment_on)
  end

  def new_member(authentik_id, approved_at: nil)
    member_in_state(authentik_id, 'new_member', "New #{authentik_id}", approved_at)
  end

  def overdue_member(authentik_id, approved_at: nil)
    member_in_state(authentik_id, 'overdue_member', "Overdue #{authentik_id}", approved_at)
  end

  def member_in_state(authentik_id, state, name, approved_at)
    user = User.create!(authentik_id: authentik_id, full_name: name,
                        email: "#{authentik_id}@example.com", membership_state: state)
    if approved_at
      MembershipApplication.create!(user: user, email: user.email, status: 'approved',
                                    reviewed_at: approved_at, submitted_at: approved_at - 2.days)
    end
    user
  end

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
