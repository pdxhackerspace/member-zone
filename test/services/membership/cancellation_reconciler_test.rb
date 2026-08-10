require 'test_helper'

module Membership
  class CancellationReconcilerTest < ActiveSupport::TestCase
    setup do
      MembershipSetting.instance.update!(overdue_grace_period_days: 30)
      EmailTemplate.where(key: %w[membership_cancelled membership_lapsed]).update_all(enabled: true)
    end

    test 'a member still covered by their last payment is recorded as cancelled' do
      cancelled_at = 3.days.ago
      user = member(dues_due_at: 2.months.from_now)
      file_cancellation(user, at: cancelled_at)

      result = reconcile_for(user)

      assert_predicate result, :applied?
      assert_equal 'cancelled_member', user.reload.membership_state
      assert_equal cancelled_at.to_i, user.membership_state_entered_at.to_i
      assert_equal cancelled_at.to_i, user.membership_cancelled_at.to_i
    end

    # The cancellation has to survive the expiry that follows it, or the lapse email finds
    # them on the way through.
    test 'a cancellation played all the way to inactive is still on record' do
      cancelled_at = 9.months.ago
      user = member(dues_due_at: 8.months.ago)
      file_cancellation(user, at: cancelled_at)

      reconcile_for(user)

      user.reload
      assert_equal 'inactive_member', user.membership_state
      assert_equal cancelled_at.to_i, user.membership_cancelled_at.to_i
    end

    test 'a cancellation that outlived its paid-through date lands the member inactive' do
      user = member(dues_due_at: 8.months.ago)
      file_cancellation(user, at: 9.months.ago)

      result = reconcile_for(user)

      assert_predicate result, :applied?
      assert_equal 'inactive_member', user.reload.membership_state
      assert_equal 'inactive_member', result.to_state
    end

    test 'a member who paid after cancelling is left alone' do
      user = member(dues_due_at: 2.months.from_now)
      file_cancellation(user, at: 6.months.ago)
      user.update_columns(last_payment_date: 1.month.ago.to_date)

      result = reconcile_for(user)

      assert_predicate result, :skipped?
      assert_equal 'paid or resubscribed since cancelling', result.reason
      assert_equal 'current_member', user.reload.membership_state
    end

    test 'a member who started a new subscription after cancelling is left alone' do
      user = member(dues_due_at: 2.months.from_now)
      file_cancellation(user, at: 6.months.ago)
      file_event(user, event_type: 'subscription_started', at: 5.months.ago)

      result = reconcile_for(user)

      assert_predicate result, :skipped?
      assert_equal 'current_member', user.reload.membership_state
    end

    test 'states an admin chose are left alone' do
      %w[banned_member deceased_member sponsored_member guest_member].each do |state|
        user = member(dues_due_at: 2.months.from_now)
        file_cancellation(user, at: 2.days.ago)
        user.update_columns(membership_state: state)

        result = reconcile_for(user.reload)

        assert_predicate result, :skipped?
        assert_equal state, user.reload.membership_state, "#{state} should be left alone"
      end
    end

    test 'a cancellation already on the record is not re-applied' do
      user = member(dues_due_at: 2.months.from_now)
      file_cancellation(user, at: 2.days.ago)
      user.record_cancellation!
      entered_at = user.membership_state_entered_at

      result = reconcile_for(user)

      assert_predicate result, :skipped?
      assert_equal 'cancellation already recorded', result.reason
      assert_equal entered_at.to_i, user.reload.membership_state_entered_at.to_i
    end

    # Nothing about their standing changes, but the reminders queued before anyone noticed
    # the cancellation are the whole reason this pass exists.
    test 'a member skipped because their cancellation is already recorded still has reminders withdrawn' do
      user = member(dues_due_at: 2.months.from_now, email: 'already-recorded@example.com')
      file_cancellation(user, at: 2.days.ago)
      user.record_cancellation!
      reminder = queue_overdue_reminder(user)

      result = reconcile_for(user)

      assert_predicate result, :skipped?
      assert_equal 1, result.withdrawn_reminders
      assert_predicate reminder.reload, :rejected?
    end

    test 'a banned member left alone still has past-due reminders withdrawn' do
      user = member(dues_due_at: 2.months.from_now, email: 'banned-reminder@example.com')
      file_cancellation(user, at: 2.days.ago)
      user.update_columns(membership_state: 'banned_member')
      reminder = queue_overdue_reminder(user)

      assert_equal 1, reconcile_for(user.reload).withdrawn_reminders
      assert_predicate reminder.reload, :rejected?
    end

    # They came back. They may genuinely owe us again, so the reminder is not ours to drop.
    test 'a member who resubscribed keeps their past-due reminders' do
      user = member(dues_due_at: 2.months.from_now, email: 'resubscribed-reminder@example.com')
      file_cancellation(user, at: 6.months.ago)
      user.update_columns(last_payment_date: 1.month.ago.to_date)
      reminder = queue_overdue_reminder(user)

      result = reconcile_for(user.reload)

      assert_predicate result, :skipped?
      assert_equal 0, result.withdrawn_reminders
      assert_predicate reminder.reload, :pending?
    end

    # A date-only payment column against a timestamped notice cannot say which came first.
    test 'a payment on the cancellation date is left for an admin rather than guessed at' do
      cancelled_at = 3.months.ago
      user = member(dues_due_at: 2.months.from_now)
      file_cancellation(user, at: cancelled_at)
      user.update_columns(last_payment_date: cancelled_at.to_date)

      result = reconcile_for(user.reload)

      assert_predicate result, :skipped?
      assert_match(/check by hand/, result.reason)
      assert_equal 'current_member', user.reload.membership_state
      assert_not_predicate user, :cancellation_recorded?
    end

    # Skipping them must not leave them exposed: the mail guards read the ledger directly.
    test 'a member left for an admin is still shielded from dues mail' do
      cancelled_at = 3.months.ago
      user = member(dues_due_at: 2.months.from_now, email: 'same-day@example.com')
      file_cancellation(user, at: cancelled_at)
      user.update_columns(last_payment_date: cancelled_at.to_date)

      assert_predicate user.reload, :cancellation_on_file?
    end

    # Nothing left to move, but "they cancelled" is the whole point: without it they are
    # indistinguishable from someone who quietly stopped paying.
    test 'a member who already fell inactive has the cancellation recorded anyway' do
      cancelled_at = 8.months.ago
      user = member(dues_due_at: 2.months.from_now)
      file_cancellation(user, at: cancelled_at)
      user.update_columns(membership_state: 'inactive_member')

      result = reconcile_for(user.reload)

      assert_predicate result, :noted?
      assert_equal 'inactive_member', user.reload.membership_state
      assert_predicate user, :cancellation_recorded?
      assert_equal cancelled_at.to_i, user.membership_cancelled_at.to_i
    end

    test 'a cancelled member missing the date gets it filled in without moving' do
      cancelled_at = 3.days.ago
      user = member(dues_due_at: 2.months.from_now)
      file_cancellation(user, at: cancelled_at)
      user.update_columns(membership_state: 'cancelled_member', membership_cancelled_at: nil)

      result = reconcile_for(user.reload)

      assert_predicate result, :noted?
      assert_equal 'cancelled_member', user.reload.membership_state
      assert_equal cancelled_at.to_i, user.membership_cancelled_at.to_i
    end

    test 'a dry run does not record the date for an already-inactive member' do
      user = member(dues_due_at: 2.months.from_now)
      file_cancellation(user, at: 8.months.ago)
      user.update_columns(membership_state: 'inactive_member')

      assert_predicate reconcile_for(user.reload, dry_run: true), :noted?
      assert_not_predicate user.reload, :cancellation_recorded?
    end

    test 'service accounts are left alone' do
      user = member(dues_due_at: 2.months.from_now)
      file_cancellation(user, at: 2.days.ago)
      user.update_columns(service_account: true)

      assert_predicate reconcile_for(user.reload), :skipped?
    end

    test 'past-due reminders waiting for review are withdrawn' do
      user = member(dues_due_at: 2.months.from_now, email: 'withdraw-reminder@example.com')
      file_cancellation(user, at: 2.days.ago)
      reminder = queue_overdue_reminder(user)

      result = reconcile_for(user)

      assert_equal 1, result.withdrawn_reminders
      assert_predicate reminder.reload, :rejected?
    end

    test 'replaying old history does not mail the member about it' do
      user = member(dues_due_at: 8.months.ago, email: 'quiet-backfill@example.com')
      file_cancellation(user, at: 9.months.ago)

      assert_no_difference 'QueuedMail.count' do
        CancellationReconciler.call
      end

      assert_equal 'inactive_member', user.reload.membership_state
    end

    test 'a dry run reports what it would do without touching anything' do
      user = member(dues_due_at: 8.months.ago, email: 'dry-run@example.com')
      file_cancellation(user, at: 9.months.ago)
      reminder = queue_overdue_reminder(user)

      result = reconcile_for(user, dry_run: true)

      assert_predicate result, :applied?
      assert_equal 'inactive_member', result.to_state
      assert_equal 1, result.withdrawn_reminders
      assert_equal 'overdue_member', user.reload.membership_state
      assert_predicate reminder.reload, :pending?
    end

    test 'only the most recent cancellation counts' do
      user = member(dues_due_at: 2.months.from_now)
      file_cancellation(user, at: 2.years.ago, subscription_id: 'old-sub')
      file_cancellation(user, at: 3.days.ago, subscription_id: 'new-sub')
      user.update_columns(last_payment_date: 1.year.ago.to_date)

      result = reconcile_for(user)

      assert_predicate result, :applied?
      assert_equal 'cancelled_member', user.reload.membership_state
    end

    private

    def reconcile_for(user, dry_run: false)
      CancellationReconciler.call(dry_run: dry_run).find { |result| result.user.id == user.id }
    end

    def member(dues_due_at:, email: nil, **attrs)
      User.create!(
        {
          authentik_id: "cancel-#{SecureRandom.hex(4)}",
          full_name: 'Cancelling Member',
          email: email || "cancel-#{SecureRandom.hex(4)}@example.com",
          payment_type: 'recharge',
          membership_state: 'current_member',
          dues_due_at: dues_due_at
        }.merge(attrs)
      ).reload
    end

    def file_cancellation(user, at:, subscription_id: SecureRandom.hex(4))
      file_event(user, event_type: 'subscription_cancelled', at: at, subscription_id: subscription_id)
    end

    def file_event(user, event_type:, at:, subscription_id: SecureRandom.hex(4))
      PaymentEvent.create!(
        user: user,
        event_type: event_type,
        source: 'recharge',
        occurred_at: at,
        external_id: "recharge-sub-#{subscription_id}-#{event_type}",
        details: "Recharge #{event_type}"
      )
    end

    def queue_overdue_reminder(user)
      QueuedMail.create!(
        to: user.email,
        subject: 'Your dues are past due',
        body_html: '<p>Hi</p>',
        body_text: 'Hi',
        reason: 'Dues overdue',
        mailer_action: 'payment_past_due',
        recipient: user,
        status: 'pending'
      )
    end
  end
end
