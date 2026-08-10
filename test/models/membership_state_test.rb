require 'test_helper'

class MembershipStateTest < ActiveSupport::TestCase
  setup do
    MembershipSetting.instance.update!(
      new_member_grace_period_days: 14,
      new_member_expiry_days: 90,
      overdue_grace_period_days: 30
    )
  end

  # ─── Onboarding ────────────────────────────────────────────────────

  # Approval is where the User record is created, so the record it starts from is a bare
  # one in 'unknown' rather than anything application-shaped.
  test 'approving an application makes someone a new member' do
    user = create_member(state: 'unknown')

    assert user.approve_application!
    assert_equal 'new_member', user.membership_state
    assert user.active?, 'a new member is active before they have paid anything'
  end

  test 'approving an application leaves an existing member where they are' do
    user = create_member(state: 'current_member')

    assert_not user.approve_application!
    assert_equal 'current_member', user.membership_state
  end

  test 'building access training starts the grace period' do
    user = create_member(state: 'new_member')

    assert user.grant_building_access!
    assert_equal 'provisional_member', user.membership_state
    assert user.active?
  end

  test 'building access training does nothing for someone already paying' do
    user = create_member(state: 'current_member')

    assert_not user.grant_building_access!
    assert_equal 'current_member', user.membership_state
  end

  test 'recording a building access training moves the trainee through the state machine' do
    user = create_member(state: 'new_member')
    topic = training_topics(:building_access)
    MembershipSetting.instance.update!(building_access_training_topic: topic)

    Training.create!(trainee: user, training_topic: topic, trained_at: Time.current)

    assert_equal 'provisional_member', user.reload.membership_state
  end

  # ─── Payment ───────────────────────────────────────────────────────

  test 'a payment makes any non-terminal member current' do
    %w[unknown new_member provisional_member overdue_member cancelled_member
       inactive_member guest_member].each do |state|
      user = create_member(state: state)

      assert user.record_payment!(last_payment_date: Date.current), "#{state} should accept a payment"
      assert_equal 'current_member', user.membership_state
    end
  end

  test 'a payment does not resurrect a banned or deceased member' do
    %w[banned_member deceased_member].each do |state|
      user = create_member(state: state)

      assert_not user.record_payment!(last_payment_date: Date.current)
      assert_equal state, user.reload.membership_state
    end
  end

  # ─── Cancellation ──────────────────────────────────────────────────

  test 'a cancellation leaves the member active until their paid-through date' do
    user = create_member(state: 'current_member', dues_due_at: 20.days.from_now)

    assert user.record_cancellation!
    assert_equal 'cancelled_member', user.membership_state
    assert user.active?, 'a cancelled member keeps the access they paid for'
  end

  test 'a repeated cancellation notice is a no-op' do
    user = create_member(state: 'current_member', dues_due_at: 20.days.from_now)
    user.record_cancellation!

    assert_not user.record_cancellation!
  end

  test 'cancelling wins over being overdue so the reminders stop' do
    user = create_member(state: 'overdue_member')

    assert user.record_cancellation!
    assert_equal 'cancelled_member', user.membership_state
  end

  # ─── Admin actions ─────────────────────────────────────────────────

  test 'banning deactivates immediately' do
    user = create_member(state: 'current_member')

    assert user.ban!
    assert_equal 'banned_member', user.membership_state
    assert_not user.active?
  end

  test 'unbanning restores a member whose payments are still current' do
    user = create_member(state: 'current_member', last_payment_date: Date.current)
    user.ban!

    assert user.unban!
    assert_equal 'current_member', user.membership_state
  end

  test 'unbanning a member with nothing paying for them leaves them inactive' do
    user = create_member(state: 'current_member')
    user.update_columns(last_payment_date: nil)
    user.ban!

    assert user.unban!
    assert_equal 'inactive_member', user.reload.membership_state
  end

  test 'unbanning someone who is not banned does nothing' do
    user = create_member(state: 'current_member')

    assert_not user.unban!
  end

  test 'marking deceased is terminal and clears the payment type' do
    user = create_member(state: 'current_member', payment_type: 'paypal')

    assert user.mark_deceased!
    assert_equal 'deceased_member', user.membership_state
    assert_equal 'inactive', user.payment_type
    assert_not user.active?
  end

  test 'sponsoring a member sets the flag and the payment type together' do
    user = create_member(state: 'overdue_member')

    assert user.mark_sponsored!
    assert_equal 'sponsored_member', user.membership_state
    assert user.is_sponsored?
    assert_equal 'sponsored', user.payment_type
    assert user.active?
  end

  test 'ending a sponsorship falls back to payment history' do
    user = create_member(state: 'current_member', last_payment_date: 2.years.ago.to_date)
    user.mark_sponsored!

    assert user.unmark_sponsored!
    assert_equal 'inactive_member', user.membership_state
    assert_not user.is_sponsored?
    assert_equal 'unknown', user.payment_type
  end

  test 'making someone a guest sets an access window' do
    user = create_member(state: 'unknown')

    travel_to Time.zone.local(2026, 3, 1, 12, 0, 0) do
      user.mark_guest!(duration_months: 3)

      assert_equal 'guest_member', user.membership_state
      assert_equal Time.zone.local(2026, 6, 1, 12, 0, 0), user.dues_due_at
    end
  end

  # ─── Illegal transitions ───────────────────────────────────────────

  test 'a deceased member cannot be moved to any other state' do
    (MembershipState::STATES - ['deceased_member']).each do |target|
      user = create_member(state: 'deceased_member')
      user.membership_state = target

      assert_not user.valid?, "deceased_member should not be able to become #{target}"
      assert_includes user.errors[:membership_state].join, 'cannot change from deceased_member'
    end
  end

  test 'a banned member cannot be quietly re-approved as a new member' do
    user = create_member(state: 'banned_member')
    user.membership_state = 'new_member'

    assert_not user.valid?, 'lifting a ban goes through unban!, which reads their payment history'
  end

  # An application is not a member and only an approved one produces a User at all, so
  # there is no applicant state to put anybody in.
  test 'applicant is not a membership state' do
    assert_not_includes MembershipState::STATES, 'applicant'

    user = create_member(state: 'new_member')
    user.membership_state = 'applicant'

    assert_not user.valid?
  end

  test 'a provisional member cannot go back to being a new member' do
    user = create_member(state: 'provisional_member')
    user.membership_state = 'new_member'

    assert_not user.valid?
  end

  test 'every transition method produces a state its guard table allows' do
    MembershipState::TRANSITIONS.each do |from, allowed|
      next if allowed == MembershipState::ANY_STATE

      allowed.each do |to|
        user = create_member(state: from)
        user.membership_state = to

        assert user.valid?, "#{from} to #{to} should be allowed but was rejected"
      end
    end
  end

  test 'an admin override permits any transition' do
    user = create_member(state: 'deceased_member')
    user.allow_any_membership_state_transition = true
    user.membership_state = 'current_member'

    assert user.valid?
  end

  # ─── Timed expiry ──────────────────────────────────────────────────

  test 'a provisional member who never pays becomes overdue when the grace period ends' do
    user = create_member(state: 'provisional_member')
    user.update_columns(membership_state_entered_at: 15.days.ago)

    assert_equal 'overdue_member', user.reload.effective_membership_state
    assert user.membership_state_expired?
  end

  test 'an overdue member becomes inactive when the overdue grace period ends' do
    user = create_member(state: 'overdue_member')
    user.update_columns(membership_state_entered_at: 31.days.ago)

    assert_equal 'inactive_member', user.reload.effective_membership_state
  end

  test 'a new member who never trains eventually lapses' do
    user = create_member(state: 'new_member')
    user.update_columns(membership_state_entered_at: 91.days.ago)

    assert_equal 'inactive_member', user.reload.effective_membership_state
  end

  test 'a cancelled member goes inactive once their paid-through date passes' do
    user = create_member(state: 'cancelled_member', dues_due_at: 1.day.ago)

    assert_equal 'inactive_member', user.reload.effective_membership_state
  end

  test 'resolution chains through several elapsed deadlines at once' do
    user = create_member(state: 'provisional_member')
    user.update_columns(membership_state_entered_at: 200.days.ago)

    assert_equal 'inactive_member', user.reload.effective_membership_state
  end

  test 'a member with no plan is measured against the payment currency window' do
    user = create_member(state: 'current_member', last_payment_date: 40.days.ago.to_date)
    user.update_columns(dues_due_at: nil)

    assert_equal 'overdue_member', user.reload.effective_membership_state
  end

  test 'expire_membership_state advances one hop at a time' do
    paid_through = 10.days.ago.beginning_of_day
    user = create_member(state: 'current_member', dues_due_at: 1.month.from_now)
    user.update_columns(
      membership_state: 'current_member',
      dues_due_at: paid_through,
      membership_state_entered_at: 90.days.ago
    )

    assert user.expire_membership_state!
    assert_equal 'overdue_member', user.membership_state
    assert_equal paid_through.to_i, user.membership_state_entered_at.to_i

    assert_not user.reload.expire_membership_state!
    assert_equal 'overdue_member', user.membership_state
  end

  test 'expire_membership_state materializes the resolved state' do
    user = create_member(state: 'overdue_member')
    user.update_columns(membership_state_entered_at: 31.days.ago)

    assert user.reload.expire_membership_state!
    assert_equal 'inactive_member', user.reload.membership_state
  end

  test 'expire_membership_state does nothing when no deadline has passed' do
    user = create_member(state: 'overdue_member')

    assert_not user.expire_membership_state!
  end

  test 'materializing overdue from a past-due current member anchors grace at paid-through' do
    paid_through = 5.days.ago.beginning_of_day
    user = create_member(state: 'current_member', dues_due_at: 1.month.from_now)
    user.update_columns(
      membership_state: 'current_member',
      dues_due_at: paid_through,
      membership_state_entered_at: 60.days.ago
    )

    user.save!

    assert_equal 'overdue_member', user.membership_state
    assert_equal paid_through.to_i, user.membership_state_entered_at.to_i
  end

  test 'record_payment stamps entered_at now even when leaving an expired state' do
    paid_through = 10.days.ago.beginning_of_day
    user = create_member(state: 'overdue_member')
    user.update_columns(membership_state_entered_at: paid_through, dues_due_at: paid_through)

    travel 1.minute do
      stamped_at = Time.current
      user.record_payment!(last_payment_date: Date.current, dues_due_at: 1.month.from_now)

      assert user.current_member?
      assert_operator user.membership_state_entered_at, :>=, stamped_at
      assert_not_equal paid_through.to_i, user.membership_state_entered_at.to_i
    end
  end

  test 'entering a state stamps when it happened' do
    user = create_member(state: 'new_member')
    original = user.membership_state_entered_at

    travel 1.day do
      user.record_payment!(last_payment_date: Date.current)
    end

    assert_operator user.membership_state_entered_at, :>, original
  end

  private

  def create_member(state:, **attrs)
    User.create!(
      {
        authentik_id: "state-#{SecureRandom.hex(4)}",
        full_name: 'State Machine Member',
        payment_type: 'unknown',
        membership_state: state
      }.merge(attrs)
    )
  end
end
