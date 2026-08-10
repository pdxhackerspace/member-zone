require 'test_helper'

# `active` is a projection of membership_state, rewritten on every save. These tests pin
# down which states open the door.
class UserComputeActiveTest < ActiveSupport::TestCase
  ACTIVE_STATES = %w[new_member provisional_member current_member overdue_member
                     cancelled_member guest_member sponsored_member].freeze
  INACTIVE_STATES = %w[unknown inactive_member banned_member deceased_member].freeze

  ACTIVE_STATES.each do |state|
    test "#{state} is active" do
      user = build_user(membership_state: state)
      user.save!
      assert user.active?, "#{state} should be active"
    end
  end

  INACTIVE_STATES.each do |state|
    test "#{state} is inactive" do
      user = build_user(membership_state: state)
      user.save!
      assert_not user.active?, "#{state} should be inactive"
    end
  end

  test 'guest membership ends when its access window closes' do
    user = build_user(membership_state: 'guest_member', dues_due_at: 2.days.ago)
    user.save!

    assert_not user.active?
    assert_equal 'inactive_member', user.membership_state
  end

  test 'sponsored membership has no access window to run out' do
    user = build_user(membership_state: 'sponsored_member', dues_due_at: 1.day.ago)
    user.save!

    assert user.active?
    assert_equal 'sponsored_member', user.membership_state
  end

  test 'deceased member gets payment_type set to inactive' do
    user = build_user(membership_state: 'deceased_member', payment_type: 'paypal')
    user.save!

    assert_equal 'inactive', user.payment_type
  end

  # ─── Emergency override ────────────────────────────────────────────

  test 'emergency override activates a member who has lapsed' do
    user = build_user(membership_state: 'inactive_member', emergency_active_override: true)
    user.save!

    assert user.active?
  end

  test 'banned member stays inactive with emergency active override' do
    user = build_user(membership_state: 'banned_member', emergency_active_override: true)
    user.save!

    assert_not user.active?, 'banned should stay inactive even with emergency override'
  end

  test 'deceased member stays inactive with emergency active override' do
    user = build_user(membership_state: 'deceased_member', emergency_active_override: true)
    user.save!

    assert_not user.active?, 'deceased should stay inactive even with emergency override'
  end

  # ─── Service account exemption ─────────────────────────────────────

  test 'service account active flag is not overridden' do
    user = build_user(membership_state: 'unknown', service_account: true, active: true)
    user.save!

    assert user.active?, 'service account active flag should not be overridden'
  end

  test 'service account can be set to inactive regardless of state' do
    user = build_user(membership_state: 'current_member', service_account: true, active: false)
    user.save!

    assert_not user.active?, 'service account inactive flag should be preserved'
  end

  test 'service account keeps its legacy status columns untouched' do
    user = build_user(membership_state: 'unknown', service_account: true, active: true,
                      membership_status: 'guest', dues_status: 'current')
    user.save!

    assert_equal 'guest', user.membership_status
    assert_equal 'current', user.dues_status
  end

  # ─── Legacy projections ────────────────────────────────────────────

  test 'membership_status and dues_status follow the state' do
    user = build_user(membership_state: 'overdue_member')
    user.save!

    assert_equal 'paying', user.membership_status
    assert_equal 'lapsed', user.dues_status
  end

  test 'banning deactivates a current member' do
    user = build_user(membership_state: 'current_member')
    user.save!
    assert user.active?

    user.ban!

    assert_not user.active?
    assert_equal 'banned', user.membership_status
  end

  test 'a payment reactivates a lapsed member' do
    user = build_user(membership_state: 'inactive_member')
    user.save!
    assert_not user.active?

    user.record_payment!(last_payment_date: Date.current)

    assert user.active?
    assert_equal 'current_member', user.membership_state
  end

  private

  def build_user(attrs = {})
    defaults = {
      authentik_id: "test-#{SecureRandom.hex(4)}",
      full_name: "Test User #{SecureRandom.hex(4)}",
      payment_type: 'unknown',
      membership_state: 'unknown',
      service_account: false,
      active: false,
      profile_visibility: 'members'
    }
    User.new(defaults.merge(attrs))
  end
end
