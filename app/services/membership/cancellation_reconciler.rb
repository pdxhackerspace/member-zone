module Membership
  # Recharge tells us when a member cancels, and we file the notice as a
  # subscription_cancelled payment event. Until the state machine existed there was nothing
  # to do with that notice, so the member's standing never moved: they stayed current, went
  # overdue on their own clock, and collected past-due reminders for a membership they had
  # already ended.
  #
  # This walks the filed notices and plays each one forward from the day it arrived —
  # cancelled while their last payment still covered them, inactive once that ran out —
  # instead of treating a two-year-old cancellation as today's news. State-entry mail is
  # suppressed for the same reason, and past-due reminders already waiting for review are
  # withdrawn.
  #
  # Members who lapsed long before anyone processed their notice are already where the
  # cancellation would have put them, so there is no state left to move. They still get the
  # date recorded: a member who cancelled and a member who quietly stopped paying look
  # identical in inactive_member, and only one of them should hear that their membership
  # lapsed.
  #
  # It is also the repair for members a payment wrongly revived after they cancelled: they
  # have no payment after the notice, so it moves them back. What a notice does to a member
  # is User#settle_cancellation!; this decides only which notices to act on.
  class CancellationReconciler
    WITHDRAWABLE_REMINDER_STATUSES = %w[pending approved].freeze

    # A reason to leave the member's standing alone, and whether the notice stands despite
    # it — which is what decides if their queued past-due mail goes.
    Skip = Struct.new(:reason, :cancellation_stands)

    Result = Struct.new(:user, :status, :cancelled_at, :from_state, :to_state, :reason, :withdrawn_reminders) do
      def applied? = status == :applied
      def noted? = status == :noted
      def skipped? = status == :skipped
    end

    def self.call(dry_run: false)
      new(dry_run: dry_run).call
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
    end

    # Returns every filed cancellation with what was (or would be) done about it, newest
    # cancellation first so the report leads with the ones an admin might still remember.
    def call
      previous_skip = Current.skip_membership_state_email
      Current.skip_membership_state_email = true

      cancellations = filed_cancellations
      users_by_id(cancellations.keys)
        .map { |user| evaluate(user, cancellations[user.id]) }
        .sort_by { |result| -result.cancelled_at.to_i }
    ensure
      Current.skip_membership_state_email = previous_skip
    end

    private

    # The most recent notice per member. An older one from a subscription they already
    # replaced says nothing about where they stand today.
    def filed_cancellations
      PaymentEvent.where(event_type: 'subscription_cancelled')
                  .where.not(user_id: nil)
                  .group(:user_id)
                  .maximum(:occurred_at)
    end

    def users_by_id(ids)
      User.where(id: ids).includes(:membership_plan).to_a
    end

    def evaluate(user, cancelled_at)
      skip = skip_decision(user, cancelled_at)
      return skipped(user, cancelled_at, skip) if skip
      return note(user, cancelled_at) if user.membership_state.in?(User::CANCELLATION_SETTLED_STATES)
      return preview(user, cancelled_at) if @dry_run

      apply(user, cancelled_at)
    end

    # Whether to leave a member's standing alone, and whether the notice still stands
    # anyway. The distinction decides their queued past-due mail: a member who came back
    # may genuinely owe us again, so their reminders stay; for everyone else the
    # cancellation holds even though there is nothing left to change, and chasing them for
    # a membership they ended is the thing this whole pass exists to stop.
    def skip_decision(user, cancelled_at)
      return Skip.new('service account', false) if user.service_account?
      return Skip.new('paid or resubscribed since cancelling', false) if user.returned_after?(cancelled_at)
      return Skip.new('cancellation already recorded', true) if user.cancellation_recorded?
      return unless user.membership_state.in?(User::CANCELLATION_LOCKED_STATES)

      Skip.new("#{user.membership_state.humanize.downcase} set deliberately", true)
    end

    def apply(user, cancelled_at)
      from_state = user.membership_state
      user.settle_cancellation!(cancelled_at)

      Result.new(user: user, status: :applied, cancelled_at: cancelled_at, from_state: from_state,
                 to_state: user.membership_state, withdrawn_reminders: settle_reminders(user))
    end

    # Their standing already reflects the cancellation; only the reason for it was missing.
    def note(user, cancelled_at)
      user.note_cancellation!(cancelled_at: cancelled_at) unless @dry_run

      Result.new(user: user, status: :noted, cancelled_at: cancelled_at, from_state: user.membership_state,
                 to_state: user.membership_state, withdrawn_reminders: settle_reminders(user))
    end

    def preview(user, cancelled_at)
      Result.new(user: user, status: :applied, cancelled_at: cancelled_at, from_state: user.membership_state,
                 to_state: user.cancellation_landing_state, withdrawn_reminders: settle_reminders(user))
    end

    def skipped(user, cancelled_at, skip)
      Result.new(user: user, status: :skipped, cancelled_at: cancelled_at, from_state: user.membership_state,
                 to_state: user.membership_state, reason: skip.reason,
                 withdrawn_reminders: skip.cancellation_stands ? settle_reminders(user) : 0)
    end

    # Reminders queued while we still believed they owed us. Nobody should have to review a
    # past-due notice for a member who cancelled, and an approved one is a send waiting to
    # happen — QueuedMailDeliveryJob re-checks the status, so rejecting stops it.
    def settle_reminders(user)
      reminders = overdue_reminders(user).to_a
      reminders.each { |mail| mail.reject!(nil) } unless @dry_run
      reminders.size
    end

    def overdue_reminders(user)
      QueuedMail.where(recipient: user, mailer_action: 'payment_past_due', sent_at: nil,
                       status: WITHDRAWABLE_REMINDER_STATUSES)
    end
  end
end
