require 'test_helper'

module Membership
  class TickJobTest < ActiveSupport::TestCase
    setup do
      MembershipSetting.instance.update!(
        new_member_grace_period_days: 14,
        new_member_expiry_days: 90,
        overdue_grace_period_days: 30
      )
    end

    test 'a provisional member past their grace period becomes overdue' do
      user = member(state: 'provisional_member', entered_at: 15.days.ago)

      assert_equal({ expired: 1, reconciled: 0 }, TickJob.new.perform)
      assert_equal 'overdue_member', user.reload.membership_state
      assert user.active?, 'the overdue grace period still lets them in'
    end

    test 'an overdue member past the overdue grace period falls inactive' do
      user = member(state: 'overdue_member', entered_at: 31.days.ago)

      TickJob.new.perform

      user.reload
      assert_equal 'inactive_member', user.membership_state
      assert_not user.active?
    end

    test 'a new member who never trained falls inactive at the cap' do
      user = member(state: 'new_member', entered_at: 91.days.ago)

      TickJob.new.perform

      assert_equal 'inactive_member', user.reload.membership_state
    end

    test 'a cancelled member falls inactive once their paid-through date passes' do
      user = member(state: 'cancelled_member')
      user.update_columns(dues_due_at: 1.day.ago)

      TickJob.new.perform

      user.reload
      assert_equal 'inactive_member', user.membership_state
      assert_not user.active?
    end

    test 'a guest falls inactive once their access window closes' do
      user = member(state: 'guest_member')
      user.update_columns(dues_due_at: 1.day.ago)

      TickJob.new.perform

      assert_equal 'inactive_member', user.reload.membership_state
    end

    test 'members whose deadlines have not arrived are left alone' do
      provisional = member(state: 'provisional_member', entered_at: 3.days.ago)
      overdue = member(state: 'overdue_member', entered_at: 3.days.ago)

      assert_equal({ expired: 0, reconciled: 0 }, TickJob.new.perform)
      assert_equal 'provisional_member', provisional.reload.membership_state
      assert_equal 'overdue_member', overdue.reload.membership_state
    end

    test 'a current member past their paid-through date becomes overdue' do
      user = member(state: 'current_member')
      user.update_columns(dues_due_at: 1.day.ago, last_payment_date: 35.days.ago.to_date)

      assert_equal({ expired: 1, reconciled: 0 }, TickJob.new.perform)

      user.reload
      assert_equal 'overdue_member', user.membership_state
      assert user.active?
    end

    test 'active reflects resolved state before the nightly tick materializes it' do
      user = member(state: 'overdue_member', entered_at: 31.days.ago)
      user.update_columns(active: true)

      assert_not user.active?
      assert user.membership_state_expired?
      assert_equal 'overdue_member', user.membership_state
    end

    test 'a stale active flag is reconciled without changing state' do
      user = member(state: 'current_member')
      user.update_columns(active: false)

      assert_equal({ expired: 0, reconciled: 1 }, TickJob.new.perform)

      user.reload
      assert user.active?
      assert user.read_attribute(:active)
      assert_equal 'current_member', user.membership_state
    end

    test 'service accounts keep whatever active flag they were given' do
      service = User.create!(
        authentik_id: "tick-service-#{SecureRandom.hex(4)}",
        full_name: 'Tick Service Account',
        service_account: true,
        active: true,
        payment_type: 'unknown'
      )

      TickJob.new.perform

      assert service.reload.active?
    end

    test 'falling inactive queues the lapsed-membership email' do
      member(state: 'overdue_member', entered_at: 31.days.ago, email: 'tick-lapsed@example.com')

      assert_difference -> { QueuedMail.where(mailer_action: 'membership_lapsed').count }, 1 do
        TickJob.new.perform
      end
    end

    private

    # Fixtures are inserted without callbacks, so every other member in the database is
    # already consistent; only the one built here should move.
    def member(state:, entered_at: nil, **attrs)
      user = User.create!(
        {
          authentik_id: "tick-#{SecureRandom.hex(4)}",
          full_name: 'Tick Member',
          payment_type: 'unknown',
          membership_state: state
        }.merge(attrs)
      )
      user.update_columns(membership_state_entered_at: entered_at) if entered_at
      user.reload
    end
  end
end
