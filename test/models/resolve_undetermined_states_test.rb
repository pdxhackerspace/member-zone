require 'test_helper'
require Rails.root.glob('db/migrate/*_resolve_undetermined_membership_states.rb').first

# AddMembershipStateMachine could only classify members whose old membership_status or
# dues_status said something, so anyone the Authentik sync or an admin created came out
# 'unknown'. A member with nothing paying for them is inactive, not undetermined; only an
# unreconciled legacy import keeps the state.
class ResolveUndeterminedStatesTest < ActiveSupport::TestCase
  setup { ActiveRecord::Migration.verbose = false }

  test 'a member who joined and never paid is inactive rather than undetermined' do
    user = undetermined

    run_migration

    assert_equal 'inactive_member', user.reload.membership_state
    assert_not_predicate user, :active?
  end

  test 'a member who is paying keeps their standing' do
    user = undetermined(last_payment_date: 3.days.ago.to_date)

    run_migration

    assert_equal 'current_member', user.reload.membership_state
    assert_predicate user, :active?
  end

  test 'a member whose payments ran out is inactive' do
    user = undetermined(last_payment_date: 90.days.ago.to_date)

    run_migration

    assert_equal 'inactive_member', user.reload.membership_state
  end

  test 'a legacy import stays undetermined' do
    user = undetermined(legacy: true)

    run_migration

    assert_equal 'unknown', user.reload.membership_state
  end

  test 'a service account is left to whatever an admin gave it' do
    user = undetermined(service_account: true)

    run_migration

    assert_equal 'unknown', user.reload.membership_state
  end

  test 'the projected columns are rewritten to match the new state' do
    user = undetermined

    run_migration

    assert_equal %w[paying lapsed], [user.reload.membership_status, user.dues_status]
  end

  test 'an emergency override still opens the door' do
    user = undetermined(emergency_active_override: true)

    run_migration

    assert_equal 'inactive_member', user.reload.membership_state
    assert_predicate user, :active?
  end

  test 'nobody is mailed about lapsing' do
    undetermined(email: 'undetermined@example.com')

    assert_no_difference 'QueuedMail.count' do
      run_migration
    end
  end

  test 'the report now asks about legacy imports only' do
    swept = undetermined
    imported = undetermined(legacy: true)

    run_migration

    undetermined_ids = User.membership_undetermined.non_service_accounts.legacy.ids

    assert_includes undetermined_ids, imported.id
    assert_not_includes undetermined_ids, swept.id
  end

  private

  def run_migration
    ResolveUndeterminedMembershipStates.new.migrate(:up)
  end

  def undetermined(**attrs)
    User.create!(
      {
        authentik_id: "undetermined-#{SecureRandom.hex(4)}",
        full_name: 'Undetermined Member',
        payment_type: 'unknown',
        membership_state: 'unknown'
      }.merge(attrs)
    )
  end
end
