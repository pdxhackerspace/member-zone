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
  class CancellationReconciler
    # States a filed cancellation must not disturb. A ban, a death, and a sponsorship were
    # each decided by a person, and a guest was never on a subscription to cancel.
    PROTECTED_STATES = %w[banned_member deceased_member sponsored_member guest_member].freeze

    # Evidence the member came back after the notice. Recharge opens a fresh subscription
    # rather than reviving the cancelled one, so a later start is a return, not a duplicate.
    RETURN_EVENT_TYPES = %w[payment subscription_started subscription_resumed].freeze

    WITHDRAWABLE_REMINDER_STATUSES = %w[pending approved].freeze

    Result = Struct.new(:user, :status, :cancelled_at, :from_state, :to_state, :reason, :withdrawn_reminders) do
      def applied? = status == :applied
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
      reason = skip_reason(user, cancelled_at)
      return skipped(user, cancelled_at, reason) if reason
      return preview(user, cancelled_at) if @dry_run

      apply(user, cancelled_at)
    end

    def skip_reason(user, cancelled_at)
      return 'service account' if user.service_account?
      return 'cancellation already recorded' if user.cancelled_member?
      return 'already inactive' if user.inactive_member?
      return 'paid or resubscribed since cancelling' if returned_after?(user, cancelled_at)

      "#{user.membership_state.humanize.downcase} set deliberately" if user.membership_state.in?(PROTECTED_STATES)
    end

    # Columns first, because a payment recorded straight onto the member never becomes a
    # payment event; then the event ledger, which is where a fresh subscription shows up.
    def returned_after?(user, cancelled_at)
      last_paid = user.last_payment_on
      return true if last_paid.present? && last_paid > cancelled_at.to_date

      PaymentEvent.for_user(user)
                  .where(event_type: RETURN_EVENT_TYPES)
                  .exists?(['payment_events.occurred_at > ?', cancelled_at])
    end

    def apply(user, cancelled_at)
      from_state = user.membership_state
      user.backdated_membership_state_entered_at = cancelled_at
      user.record_cancellation!
      play_forward(user)

      Result.new(user: user, status: :applied, cancelled_at: cancelled_at, from_state: from_state,
                 to_state: user.membership_state, withdrawn_reminders: withdraw_overdue_reminders(user))
    end

    def preview(user, cancelled_at)
      Result.new(user: user, status: :applied, cancelled_at: cancelled_at, from_state: user.membership_state,
                 to_state: projected_state(user), withdrawn_reminders: overdue_reminders(user).count)
    end

    def skipped(user, cancelled_at, reason)
      Result.new(user: user, status: :skipped, cancelled_at: cancelled_at, from_state: user.membership_state,
                 to_state: user.membership_state, reason: reason, withdrawn_reminders: 0)
    end

    # Where a cancellation recorded today leaves the member: still covered by their last
    # payment, or past the date it covered them through.
    def projected_state(user)
      paid_through = user.dues_paid_through_at
      paid_through.present? && paid_through <= Time.current ? 'inactive_member' : 'cancelled_member'
    end

    # A cancellation filed long enough ago has a second deadline behind it — the
    # paid-through date it outlived. Materialization advances one state per save.
    def play_forward(user)
      MembershipStateResolution::MAX_EXPIRY_HOPS.times do
        break unless user.expire_membership_state!
      end
    end

    # Reminders queued while we still believed they owed us. Nobody should have to review a
    # past-due notice for a member who cancelled, and an approved one is a send waiting to
    # happen — QueuedMailDeliveryJob re-checks the status, so rejecting stops it.
    def withdraw_overdue_reminders(user)
      reminders = overdue_reminders(user).to_a
      reminders.each { |mail| mail.reject!(nil) }
      reminders.size
    end

    def overdue_reminders(user)
      QueuedMail.where(recipient: user, mailer_action: 'payment_past_due', sent_at: nil,
                       status: WITHDRAWABLE_REMINDER_STATUSES)
    end
  end
end
