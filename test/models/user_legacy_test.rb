require 'test_helper'

class UserLegacyTest < ActiveSupport::TestCase
  # ─── Scopes ────────────────────────────────────────────────────────

  test 'legacy scope returns only legacy users' do
    legacy_user = create_user(legacy: true)
    regular_user = create_user(legacy: false)

    assert_includes User.legacy, legacy_user
    assert_not_includes User.legacy, regular_user
  end

  test 'non_legacy scope excludes legacy users' do
    legacy_user = create_user(legacy: true)
    regular_user = create_user(legacy: false)

    assert_not_includes User.non_legacy, legacy_user
    assert_includes User.non_legacy, regular_user
  end

  test 'legacy defaults to false' do
    user = User.new(authentik_id: 'test-default', full_name: 'Default Test', payment_type: 'unknown')
    assert_not user.legacy?
  end

  # ─── Journal suppression: marking as legacy ────────────────────────

  test 'marking as legacy does not create a journal entry' do
    user = create_user(legacy: false)
    initial_journal_count = user.journals.count

    user.update!(legacy: true)

    assert_equal initial_journal_count, user.journals.count,
                 'No journal entry should be created when marking as legacy'
  end

  test 'marking as legacy with other changes still creates a journal entry' do
    user = create_user(legacy: false, full_name: 'Old Name')
    initial_journal_count = user.journals.count

    user.update!(legacy: true, full_name: 'New Name')

    assert_operator user.journals.count, :>, initial_journal_count,
                    'Journal entry should be created when legacy is set alongside other changes'
  end

  # ─── Journal entry: un-marking legacy ──────────────────────────────

  test 'un-marking legacy creates a journal entry' do
    user = create_user(legacy: true)
    initial_journal_count = user.journals.count

    user.update!(legacy: false)

    assert_operator user.journals.count, :>, initial_journal_count,
                    'Journal entry should be created when un-marking legacy'
  end

  # ─── Auto-clear legacy when meaningful data arrives ────────────────

  test 'setting a membership plan clears legacy flag' do
    plan = MembershipPlan.create!(name: "Auto-clear Plan #{SecureRandom.hex(4)}", cost: 50,
                                  billing_frequency: 'monthly', plan_type: 'primary')
    user = create_user(legacy: true)

    user.update!(membership_plan: plan)

    assert_not user.legacy?, 'Legacy should be cleared when a membership plan is set'
  end

  test 'a payment clears the legacy flag' do
    user = create_user(legacy: true)

    user.record_payment!(last_payment_date: Date.current)

    assert_not user.legacy?, 'Legacy should be cleared when a payment lands'
  end

  test 'lapsing clears the legacy flag' do
    user = create_user(legacy: true)

    user.update!(membership_state: 'inactive_member')

    assert_not user.legacy?, 'Legacy should be cleared once the membership state is determined'
  end

  test 'a membership state that stays unknown does NOT clear legacy flag' do
    user = create_user(legacy: true)

    user.update!(full_name: "Updated Name #{SecureRandom.hex(4)}")

    assert user.legacy?, 'Legacy should NOT be cleared when the membership state stays unknown'
  end

  test 'setting last_payment_date clears legacy flag' do
    user = create_user(legacy: true)

    user.update!(last_payment_date: Date.current)

    assert_not user.legacy?, 'Legacy should be cleared when last_payment_date is set'
  end

  test 'setting recharge_most_recent_payment_date clears legacy flag' do
    user = create_user(legacy: true)

    user.update!(recharge_most_recent_payment_date: Time.current)

    assert_not user.legacy?, 'Legacy should be cleared when recharge_most_recent_payment_date is set'
  end

  test 'becoming a current member clears legacy flag' do
    user = create_user(legacy: true)

    user.update!(membership_state: 'current_member')

    assert_not user.legacy?, 'Legacy should be cleared when the member starts paying'
  end

  test 'being sponsored clears legacy flag' do
    user = create_user(legacy: true)

    user.mark_sponsored!

    assert_not user.legacy?, 'Legacy should be cleared when the member is sponsored'
  end

  # ─── Regression: setting legacy must not be undone by existing data ──

  test 'marking legacy sticks even when the member has already lapsed' do
    user = create_user(legacy: false, membership_state: 'inactive_member')

    user.update!(legacy: true)
    user.reload

    assert user.legacy?, 'Legacy should stick when set on a member who has already lapsed'
  end

  test 'marking legacy sticks even when the member is overdue' do
    user = create_user(legacy: false, membership_state: 'overdue_member')

    user.update!(legacy: true)
    user.reload

    assert user.legacy?, 'Legacy should stick when set on a member who is behind on dues'
  end

  test 'marking legacy sticks even when membership_plan is set' do
    plan = MembershipPlan.create!(name: "Sticky Plan #{SecureRandom.hex(4)}", cost: 50, billing_frequency: 'monthly',
                                  plan_type: 'primary')
    user = create_user(legacy: false)
    user.update_columns(membership_plan_id: plan.id)

    user.update!(legacy: true)
    user.reload

    assert user.legacy?, 'Legacy should stick when set on a member that already has a plan'
  end

  # ─── Auto-clear journal ────────────────────────────────────────────

  test 'auto-clear of legacy creates a journal entry' do
    user = create_user(legacy: true)
    initial_journal_count = user.journals.count

    user.update!(membership_state: 'current_member')

    assert_not user.legacy?
    assert_operator user.journals.count, :>, initial_journal_count,
                    'Journal entry should be created when legacy is auto-cleared'
  end

  private

  def create_user(attrs = {})
    defaults = {
      authentik_id: "legacy-test-#{SecureRandom.hex(4)}",
      full_name: "Legacy Test #{SecureRandom.hex(4)}",
      payment_type: 'unknown',
      legacy: false
    }
    User.create!(defaults.merge(attrs))
  end
end
