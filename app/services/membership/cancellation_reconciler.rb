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
  class CancellationReconciler
    # States a filed cancellation must not disturb. A ban, a death, and a sponsorship were
    # each decided by a person, and a guest was never on a subscription to cancel.
    PROTECTED_STATES = %w[banned_member deceased_member sponsored_member guest_member].freeze

    # Evidence the member came back after the notice. Recharge opens a fresh subscription
    # rather than reviving the cancelled one, so a later start is a return, not a duplicate.
    RETURN_EVENT_TYPES = %w[payment subscription_started subscription_resumed].freeze

    # Nowhere left to go. inactive_member is where a cancellation ends up anyway, and a
    # cancelled_member missing its date only needs the date.
    NOTE_ONLY_STATES = %w[cancelled_member inactive_member].freeze

    WITHDRAWABLE_REMINDER_STATUSES = %w[pending approved].freeze

    SAME_DAY_PAYMENT_REASON = 'paid on the cancellation date; check by hand'.freeze

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
      return note(user, cancelled_at) if user.membership_state.in?(NOTE_ONLY_STATES)
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
      return Skip.new('paid or resubscribed since cancelling', false) if returned_after?(user, cancelled_at)
      return Skip.new(SAME_DAY_PAYMENT_REASON, false) if paid_on_cancellation_date?(user, cancelled_at)
      return Skip.new('cancellation already recorded', true) if user.cancellation_recorded?
      return unless user.membership_state.in?(PROTECTED_STATES)

      Skip.new("#{user.membership_state.humanize.downcase} set deliberately", true)
    end

    # Columns first, because a payment recorded straight onto the member never becomes a
    # payment event; then the event ledger, which is where a fresh subscription shows up
    # and where the timestamps are precise enough to order same-day activity.
    def returned_after?(user, cancelled_at)
      last_paid = user.last_payment_on
      return true if last_paid.present? && last_paid > cancelled_at.to_date

      PaymentEvent.for_user(user)
                  .where(event_type: RETURN_EVENT_TYPES)
                  .exists?(['payment_events.occurred_at > ?', cancelled_at])
    end

    # last_payment_on is a date and the notice is a timestamp, so a payment on the same day
    # is either a same-day resubscribe or the renewal they cancelled straight afterwards,
    # and the records cannot say which. A bulk pass should not guess; the mail guards read
    # the ledger directly, so nobody gets chased while an admin sorts it out.
    def paid_on_cancellation_date?(user, cancelled_at)
      user.last_payment_on.present? && user.last_payment_on == cancelled_at.to_date
    end

    def apply(user, cancelled_at)
      from_state = user.membership_state
      user.backdated_membership_state_entered_at = cancelled_at
      user.record_cancellation!(cancelled_at: cancelled_at)
      play_forward(user)

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
                 to_state: projected_state(user), withdrawn_reminders: settle_reminders(user))
    end

    def skipped(user, cancelled_at, skip)
      Result.new(user: user, status: :skipped, cancelled_at: cancelled_at, from_state: user.membership_state,
                 to_state: user.membership_state, reason: skip.reason,
                 withdrawn_reminders: skip.cancellation_stands ? settle_reminders(user) : 0)
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
