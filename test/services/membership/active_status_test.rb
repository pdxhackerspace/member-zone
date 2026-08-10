require 'test_helper'

module Membership
  # The rules themselves are covered by MembershipStateTest; this only checks that the
  # adapter still forwards to the state machine for callers that pre-date it.
  class ActiveStatusTest < ActiveSupport::TestCase
    test 'compute follows the membership state' do
      assert ActiveStatus.compute(build_user(membership_state: 'current_member'))
      assert_not ActiveStatus.compute(build_user(membership_state: 'inactive_member'))
    end

    test 'terminal_membership? recognises bans and deaths' do
      assert ActiveStatus.terminal_membership?(build_user(membership_state: 'banned_member'))
      assert ActiveStatus.terminal_membership?(build_user(membership_state: 'deceased_member'))
      assert_not ActiveStatus.terminal_membership?(build_user(membership_state: 'overdue_member'))
    end

    test 'apply_to sets deceased payment type inactive' do
      user = build_user(membership_state: 'deceased_member', payment_type: 'paypal')
      user.save!

      ActiveStatus.apply_to(user)

      assert_not user.active
      assert_equal 'inactive', user.payment_type
    end

    test 'reconcile activates a member whose cached flag drifted' do
      user = build_user(membership_state: 'sponsored_member')
      user.save!
      user.update_columns(active: false)

      assert ActiveStatus.reconcile!(user)
      assert user.reload.active
    end

    test 'reconcile materializes a deadline that has already passed' do
      user = build_user(membership_state: 'guest_member', dues_due_at: 1.day.from_now)
      user.save!
      user.update_columns(dues_due_at: 1.day.ago)

      assert ActiveStatus.reconcile!(user)

      user.reload
      assert_equal 'inactive_member', user.membership_state
      assert_not user.active
    end

    test 'reconcile leaves a member who is already correct alone' do
      user = build_user(membership_state: 'current_member')
      user.save!

      assert_not ActiveStatus.reconcile!(user)
    end

    test 'assign_and_save recomputes active from the new state' do
      user = build_user(membership_state: 'inactive_member')
      user.save!

      ActiveStatus.assign_and_save!(user, membership_state: 'current_member')

      assert user.reload.active
    end

    test 'assign_and_save lifts the transition guard for bulk backfills' do
      user = build_user(membership_state: 'current_member')
      user.save!

      ActiveStatus.assign_and_save!(user, membership_state: 'unknown')

      assert_equal 'unknown', user.reload.membership_state
    end

    test 'record_linked_payment skips payment-immune states' do
      user = build_user(membership_state: 'sponsored_member', is_sponsored: true, payment_type: 'sponsored')
      user.save!

      assert_not ActiveStatus.record_linked_payment!(user, last_payment_date: Date.current)

      assert_equal 'sponsored_member', user.reload.membership_state
    end

    test 'record_linked_payment moves a lapsed member back when their payment still covers them' do
      user = build_user(membership_state: 'inactive_member', last_payment_date: 1.year.ago.to_date)
      user.save!

      assert ActiveStatus.record_linked_payment!(user, last_payment_date: Date.current, payment_type: 'paypal')

      assert_equal 'current_member', user.reload.membership_state
      assert user.active?
    end

    test 'service account active flag is not recomputed' do
      user = User.create!(
        authentik_id: 'service-active-status',
        full_name: 'Service Account',
        service_account: true,
        active: false,
        payment_type: 'unknown'
      )

      assert_not ActiveStatus.reconcile!(user)
      assert_not user.reload.active
    end

    private

    def build_user(**attrs)
      defaults = {
        authentik_id: SecureRandom.hex(4),
        full_name: 'Active Status Test',
        payment_type: 'unknown'
      }
      User.new(defaults.merge(attrs))
    end
  end
end
