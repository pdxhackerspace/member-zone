require 'test_helper'

module Membership
  class StateTickTest < ActiveSupport::TestCase
    setup do
      MembershipSetting.instance.update!(overdue_grace_period_days: 30)
    end

    test 'reports a member whose deadline has passed as stale' do
      user = member(state: 'overdue_member', entered_at: 31.days.ago)

      tick = StateTick.new(user)

      assert_predicate tick, :stale?
      assert_match(/state overdue_member -> inactive_member/, tick.summary_line)
    end

    test 'reports a cached active flag that drifted from the resolved state' do
      user = member(state: 'current_member')
      user.update_columns(active: false)

      tick = StateTick.new(user)

      assert_predicate tick, :stale?
      assert_match(/active false -> true/, tick.summary_line)
    end

    test 'materializes an expiry without touching members who are still on time' do
      user = member(state: 'overdue_member', entered_at: 31.days.ago)

      result = StateTick.call(user)

      assert_predicate result, :expired?
      assert_equal 'inactive_member', user.reload.membership_state
    end

    test 'reconciles a stale active column without changing state' do
      user = member(state: 'current_member')
      user.update_columns(active: false)

      result = StateTick.call(user)

      assert_predicate result, :reconciled?
      assert user.reload.read_attribute(:active)
      assert_equal 'current_member', user.membership_state
    end

    private

    def member(state:, entered_at: nil, **attrs)
      user = User.create!(
        {
          authentik_id: "state-tick-#{SecureRandom.hex(4)}",
          full_name: 'State Tick Member',
          payment_type: 'unknown',
          membership_state: state
        }.merge(attrs)
      )
      user.update_columns(membership_state_entered_at: entered_at) if entered_at
      user.reload
    end
  end
end
