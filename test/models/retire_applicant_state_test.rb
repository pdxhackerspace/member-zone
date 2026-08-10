require 'test_helper'
require Rails.root.glob('db/migrate/*_retire_applicant_membership_state.rb').first

# AddMembershipStateMachine leaves users whose old membership_status was 'applicant' on an
# 'applicant' state that no longer exists. They are not applicants — they are members whose
# applications were approved and who were never moved on — so this migration sorts them
# into where their payment history and the onboarding clock actually put them.
class RetireApplicantStateTest < ActiveSupport::TestCase
  setup do
    MembershipSetting.instance.update!(new_member_expiry_days: 90)
    ActiveRecord::Migration.verbose = false
  end

  test 'a recently approved member who never paid is still onboarding' do
    user = stranded_applicant(created_at: 10.days.ago)

    run_migration

    assert_equal 'new_member', user.reload.membership_state
    assert_predicate user, :active?
  end

  test 'an approved member who never paid and never came back is inactive' do
    user = stranded_applicant(created_at: 2.years.ago)

    run_migration

    assert_equal 'inactive_member', user.reload.membership_state
    assert_not_predicate user, :active?
  end

  # The bug this fixes: the original backfill tested membership_status before dues, so a
  # member who was paying all along was filed under a pre-payment state.
  test 'a member who was paying keeps their standing' do
    user = stranded_applicant(created_at: 3.years.ago, last_payment_date: 5.days.ago.to_date)

    run_migration

    assert_equal 'current_member', user.reload.membership_state
    assert_predicate user, :active?
  end

  test 'a member whose payments ran out lapses rather than restarting onboarding' do
    user = stranded_applicant(created_at: 3.years.ago, last_payment_date: 400.days.ago.to_date)

    run_migration

    assert_equal 'inactive_member', user.reload.membership_state
    assert_not_predicate user, :active?
  end

  test 'a recharge payment counts as payment history' do
    user = stranded_applicant(created_at: 3.years.ago, recharge_most_recent_payment_date: 5.days.ago)

    run_migration

    assert_equal 'current_member', user.reload.membership_state
  end

  test 'the projected columns are rewritten to match the new state' do
    onboarding = stranded_applicant(created_at: 10.days.ago)
    lapsed = stranded_applicant(created_at: 2.years.ago)

    run_migration

    assert_equal %w[paying current], [onboarding.reload.membership_status, onboarding.dues_status]
    assert_equal %w[paying lapsed], [lapsed.reload.membership_status, lapsed.dues_status]
  end

  test 'an emergency override still opens the door' do
    user = stranded_applicant(created_at: 2.years.ago, emergency_active_override: true)

    run_migration

    assert_equal 'inactive_member', user.reload.membership_state
    assert_predicate user, :active?
  end

  test 'a service account keeps the access an admin gave it' do
    user = stranded_applicant(created_at: 2.years.ago, service_account: true, active: true)

    run_migration

    assert_predicate user.reload, :active?
  end

  # Resolving the expiry here rather than leaving it to Membership::TickJob is the whole
  # reason this is done in SQL: the job would mail every dormant member on the way past.
  test 'nobody is mailed about lapsing' do
    stranded_applicant(created_at: 2.years.ago, email: 'stranded@example.com')

    assert_no_difference 'QueuedMail.count' do
      run_migration
    end
  end

  test 'members in other states are left alone' do
    current = User.create!(authentik_id: "untouched-#{SecureRandom.hex(4)}", full_name: 'Untouched',
                           payment_type: 'unknown', membership_state: 'guest_member')

    run_migration

    assert_equal 'guest_member', current.reload.membership_state
  end

  private

  def run_migration
    RetireApplicantMembershipState.new.migrate(:up)
  end

  # Builds the row AddMembershipStateMachine would have left behind: state 'applicant',
  # entered_at anchored on the approval date. update_all with raw SQL because the enum no
  # longer accepts the value.
  def stranded_applicant(created_at:, **attrs)
    user = User.create!(
      {
        authentik_id: "stranded-#{SecureRandom.hex(4)}",
        full_name: 'Stranded Applicant',
        payment_type: 'unknown'
      }.merge(attrs)
    )
    user.update_columns(created_at: created_at, membership_state_entered_at: created_at)
    User.where(id: user.id).update_all("membership_state = 'applicant'")
    user
  end
end
