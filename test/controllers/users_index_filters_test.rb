require 'test_helper'

class UsersIndexFiltersTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # ─── Basic index ───────────────────────────────────────────────────

  test 'index loads successfully' do
    get users_path
    assert_response :success
  end

  test 'profile links in turbo results navigate the full page' do
    get users_path
    assert_response :success

    assert_select 'turbo-frame#users_results a[href=?][data-turbo-frame=?]', user_path(users(:one)), '_top'
  end

  test 'searched profile links in turbo results navigate the full page' do
    get users_path(q: users(:one).display_name)
    assert_response :success

    profile_path = user_path(users(:one), q: users(:one).display_name)
    assert_select 'turbo-frame#users_results a[href=?][data-turbo-frame=?]', profile_path, '_top'
  end

  # ─── Payment Plan filtering ────────────────────────────────────────

  test 'index shows payment plan badges' do
    plan = MembershipPlan.create!(name: 'Test Monthly Plan', cost: 50, billing_frequency: 'monthly',
                                  plan_type: 'primary')
    users(:one).update_columns(membership_plan_id: plan.id)

    get users_path
    assert_response :success
    assert_match(/Payment plan/i, response.body)
    assert_match 'Test Monthly Plan', response.body
  end

  test 'filtering by membership_plan_id returns members on that plan' do
    plan = MembershipPlan.create!(name: 'Filter Plan', cost: 75, billing_frequency: 'monthly', plan_type: 'primary')
    users(:one).update_columns(membership_plan_id: plan.id)

    get users_path(membership_plan_id: plan.id)
    assert_response :success
    assert_match users(:one).display_name, response.body
  end

  test 'filtering by membership_plan_id=none returns members without a plan' do
    # Ensure user :one has no plan
    users(:one).update_columns(membership_plan_id: nil)

    get users_path(membership_plan_id: 'none')
    assert_response :success
    assert_match users(:one).display_name, response.body
  end

  test 'filter info bar shows plan name when filtering' do
    plan = MembershipPlan.create!(name: 'Info Bar Plan', cost: 30, billing_frequency: 'monthly', plan_type: 'primary')
    users(:one).update_columns(membership_plan_id: plan.id)

    get users_path(membership_plan_id: plan.id)
    assert_response :success
    assert_match 'Info Bar Plan', response.body
  end

  test 'filter info bar shows No Plan when filtering by none' do
    get users_path(membership_plan_id: 'none')
    assert_response :success
    assert_match 'No Plan', response.body
  end

  # ─── Service account filtering ─────────────────────────────────────

  test 'filtering by account_type=service shows only service accounts' do
    User.create!(
      authentik_id: "sa-filter-#{SecureRandom.hex(4)}",
      full_name: 'Service Filter Test',
      payment_type: 'unknown',
      service_account: true,
      active: true
    )

    get users_path(account_type: 'service')
    assert_response :success
    assert_match 'Service Filter Test', response.body
  end

  test 'filtering by account_type=member excludes service accounts' do
    User.create!(
      authentik_id: "sa-exclude-#{SecureRandom.hex(4)}",
      full_name: 'Service Exclude Test',
      payment_type: 'unknown',
      service_account: true,
      active: true
    )

    get users_path(account_type: 'member')
    assert_response :success
    assert_no_match(/Service Exclude Test/, response.body)
  end

  # ─── Membership state filtering ────────────────────────────────────

  test 'filtering by membership_state works' do
    users(:one).update_columns(membership_state: 'sponsored_member')

    get users_path(membership_state: 'sponsored_member')
    assert_response :success
    assert_match users(:one).display_name, response.body
  end

  # ─── Payment type filtering ────────────────────────────────────────

  test 'filtering by payment_type works' do
    users(:one).update_columns(payment_type: 'paypal')

    get users_path(payment_type: 'paypal')
    assert_response :success
    assert_match users(:one).display_name, response.body
  end

  # ─── Overdue filtering ─────────────────────────────────────────────

  test 'filtering by an overdue membership state works' do
    users(:one).update_columns(membership_state: 'overdue_member')

    get users_path(membership_state: 'overdue_member')
    assert_response :success
    assert_match users(:one).display_name, response.body
  end

  # ─── Key access paused filtering ───────────────────────────────────

  test 'index shows key paused filter badge' do
    get users_path
    assert_response :success
    assert_match(/Key paused/i, response.body)
    assert_select 'a[href*="key_access=paused"]'
  end

  test 'filtering by key_access=paused returns only paused members' do
    users(:one).pause_key_access!
    users(:two).resume_key_access!

    get users_path(key_access: 'paused')
    assert_response :success
    assert_match users(:one).display_name, response.body
    assert_no_match(/#{Regexp.escape(users(:two).display_name)}/, response.body)
  end

  test 'key access paused filter shows in the active filter summary' do
    get users_path(key_access: 'paused')
    assert_response :success
    assert_match 'Key access paused', response.body
  end

  # ─── Combined / stacking filters ──────────────────────────────────

  test 'clear all filters link is shown when filter active' do
    get users_path(payment_type: 'paypal')
    assert_response :success
    assert_match 'Clear all filters', response.body
  end

  test 'stacking two filters returns intersection' do
    users(:one).update_columns(membership_state: 'overdue_member', payment_type: 'paypal')
    users(:two).update_columns(membership_state: 'current_member', payment_type: 'paypal')
    users(:three).update_columns(membership_state: 'overdue_member', payment_type: 'cash')

    get users_path(membership_state: 'overdue_member', payment_type: 'paypal')
    assert_response :success
    assert_match users(:one).display_name, response.body
    assert_no_match(/#{Regexp.escape(users(:two).display_name)}/, response.body)
    assert_no_match(/#{Regexp.escape(users(:three).display_name)}/, response.body)
  end

  test 'stacking three filters narrows results further' do
    users(:one).update_columns(membership_state: 'overdue_member', payment_type: 'paypal', legacy: false)
    users(:cash_payer).update_columns(membership_state: 'overdue_member', payment_type: 'cash')

    get users_path(membership_state: 'overdue_member', payment_type: 'paypal', active: 'true')
    assert_response :success
    assert_match users(:one).display_name, response.body
    assert_no_match(/Cash Payer User/, response.body)
  end

  test 'badge counts reflect the filtered set' do
    users(:one).update_columns(membership_state: 'overdue_member', payment_type: 'paypal')
    users(:two).update_columns(membership_state: 'sponsored_member', payment_type: 'paypal')

    get users_path(payment_type: 'paypal')
    assert_response :success

    assert_select 'a[href*="membership_state=overdue_member"]', /Overdue\s+\d+/
    assert_select 'a[href*="membership_state=sponsored_member"]', /Sponsored\s+\d+/
  end

  test 'filter summary shows all active filter labels' do
    get users_path(membership_state: 'overdue_member', payment_type: 'paypal')
    assert_response :success
    assert_match 'Membership: Overdue', response.body
    assert_match 'Payment: Paypal', response.body
  end

  test 'badge links preserve existing filter params' do
    users(:one).update_columns(membership_state: 'overdue_member', payment_type: 'paypal')

    get users_path(payment_type: 'paypal')
    assert_response :success
    assert_select 'a[href*="payment_type=paypal"][href*="membership_state=overdue_member"]'
  end

  test 'clicking an applied filter chip toggles it off (link without that param)' do
    users(:one).update_columns(membership_state: 'overdue_member')

    get users_path(membership_state: 'overdue_member')
    assert_response :success

    assert_select 'a.filter-chip.active' do |elements|
      chip = elements.find { |e| e.text.include?('Overdue') }
      assert chip, 'Expected a highlighted Overdue chip'
      assert_not_includes chip['href'], 'membership_state='
    end
  end

  # ─── Legacy stacking ────────────────────────────────────────────

  test 'legacy toggle stacks with other filters' do
    users(:one).update_columns(legacy: true, membership_state: 'current_member')

    get users_path(include_legacy: '1', membership_state: 'current_member')
    assert_response :success
    assert_match users(:one).display_name, response.body
    assert_match 'Including legacy', response.body
  end

  test 'legacy badge preserves other active filters' do
    users(:one).update_columns(legacy: true)
    get users_path(payment_type: 'paypal')
    assert_response :success
    # The legacy checkbox onchange URL should include both include_legacy and current filter params
    assert_match(/include_legacy/, response.body)
    assert_match(/payment_type.*paypal|paypal.*payment_type/, response.body)
  end

  private

  def sign_in_as_local_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: { email: account.email, password: 'localpassword123' }
    }
  end
end
