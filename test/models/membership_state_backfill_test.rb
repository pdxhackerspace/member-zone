require 'test_helper'
# Migrations are outside the autoload paths, and the mapping under test only exists there.
require Rails.root.glob('db/migrate/*_add_membership_state_machine.rb').first

# The membership_state column was populated from the three fields it replaces. The mapping
# lives in the migration, so this exercises it directly against rows inserted the way the
# old code would have left them.
class MembershipStateBackfillTest < ActiveSupport::TestCase
  CASES = {
    'banned_member' => { membership_status: 'banned', dues_status: 'current' },
    'deceased_member' => { membership_status: 'deceased', dues_status: 'current' },
    'guest_member' => { membership_status: 'guest', dues_status: 'unknown' },
    'cancelled_member' => { membership_status: 'cancelled', dues_status: 'lapsed' },
    'current_member' => { membership_status: 'paying', dues_status: 'current' },
    'inactive_member' => { membership_status: 'paying', dues_status: 'lapsed' },
    'unknown' => { membership_status: 'unknown', dues_status: 'unknown' }
  }.freeze

  CASES.each do |expected_state, columns|
    test "#{columns[:membership_status]} with #{columns[:dues_status]} dues backfills to #{expected_state}" do
      assert_equal expected_state, backfilled_state(**columns)
    end
  end

  test 'every one of the three sponsored signals backfills to sponsored_member' do
    assert_equal 'sponsored_member', backfilled_state(membership_status: 'sponsored', dues_status: 'lapsed')
    assert_equal 'sponsored_member', backfilled_state(membership_status: 'paying', dues_status: 'lapsed',
                                                      is_sponsored: true)
    assert_equal 'sponsored_member', backfilled_state(membership_status: 'unknown', dues_status: 'unknown',
                                                      payment_type: 'sponsored')
  end

  test 'a ban outranks sponsorship' do
    assert_equal 'banned_member', backfilled_state(membership_status: 'banned', dues_status: 'current',
                                                   is_sponsored: true)
  end

  test 'current dues rescue a member whose membership status was never determined' do
    assert_equal 'current_member', backfilled_state(membership_status: 'unknown', dues_status: 'current')
  end

  # The old code left every user it created at approval on membership_status 'applicant',
  # so this rule catches approved members rather than actual applicants.
  # RetireApplicantMembershipState sorts them out; see its test.
  test 'the applicant rule fires before dues are considered' do
    assert_equal 'applicant', backfilled_state(membership_status: 'applicant', dues_status: 'current')
  end

  private

  # Inserts a row the way the pre-state-machine app would have, then replays the
  # migration's rules over it.
  def backfilled_state(**columns)
    user = User.create!(
      authentik_id: "backfill-#{SecureRandom.hex(4)}",
      full_name: 'Backfill Subject',
      payment_type: columns.fetch(:payment_type, 'unknown')
    )
    user.update_columns(membership_state: 'unknown', **columns)

    AddMembershipStateMachine::STATE_BACKFILL.each do |condition, state|
      User.where(id: user.id).where(membership_state: 'unknown').where(condition)
          .update_all(membership_state: state)
    end

    # Read around the enum: this migration can leave a row on 'applicant', which is no
    # longer one of the declared states.
    User.connection.select_value(User.where(id: user.id).select(:membership_state).to_sql)
  end
end
