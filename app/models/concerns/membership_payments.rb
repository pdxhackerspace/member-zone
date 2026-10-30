# What a payment and a cancellation do to a member's standing. Every caller — the PayPal,
# Recharge, and Ko-fi syncs, cash payments, the cancellation webhooks and reconciler, and
# the rake tasks — asks these methods rather than deciding for itself, so the rules below
# are the whole of them:
#
# - Only a real payment makes someone current. An admin marking a member paid records a
#   cash payment; nothing else takes the current_member edge from the payment side.
# - A cancelled member keeps access until their paid-through date, then expires to
#   inactive_member. The cancellation stays on file through both.
# - A payment after the cancellation brings them back. A timed charge has to be later than
#   the notice; a cash payment carries only a date, so one dated on the cancellation day
#   or later counts.
# - A payment re-read from history is not news. A payment seen for the first time always
#   is; one read again by a sync or a cleanup task counts only if it is dated on or after
#   the day the member entered their current state.
module MembershipPayments
  extend ActiveSupport::Concern

  # Set deliberately by a person; a payment does not reverse the decision. A sponsored
  # member's payment is still recorded, their standing just stays put.
  PAYMENT_LOCKED_STATES = %w[banned_member deceased_member sponsored_member].freeze

  # States a cancellation notice must not disturb. A guest was never on a subscription.
  CANCELLATION_LOCKED_STATES = %w[banned_member deceased_member sponsored_member guest_member].freeze

  # Already where a cancellation leads, so the notice only needs its date recorded.
  CANCELLATION_SETTLED_STATES = %w[cancelled_member inactive_member].freeze

  # Payment events that say a member came back. Recharge opens a fresh subscription rather
  # than reviving the cancelled one, so a later start is a return rather than a duplicate of
  # the notice.
  RETURN_EVENT_TYPES = %w[payment subscription_started subscription_resumed].freeze

  # Whether a payment brings the member back to current_member. paid_at is a Time for a
  # timed charge, or a Date for a cash payment. first_seen says the caller has never
  # applied this payment before — a new charge or a newly linked one.
  def payment_revives?(paid_at, first_seen: false)
    return false if paid_at.blank?
    return false if membership_state.in?(PAYMENT_LOCKED_STATES) || is_sponsored?
    return false unless payment_after?(paid_at, latest_cancellation_at)
    # Nothing has brought them back since the recorded cancellation, so every payment after
    # it is one we have not acted on.
    return true if first_seen || cancellation_recorded?

    !before_state_entry?(paid_at.to_date)
  end

  # Records a payment whose bookkeeping the caller has already worked out. Whether it
  # revives the member is payment_revives?; if their last payment no longer covers them,
  # the expiry resolution on save moves them straight on.
  def record_payment!(paid_at:, first_seen: false, **attrs)
    return record_payment_bookkeeping!(**attrs) unless payment_revives?(paid_at, first_seen: first_seen)

    transition_to!('current_member', **attrs, membership_ended_date: nil)
  end

  # The column updates a payment implies, merged into updates for the caller to save with
  # whatever else it is changing. Accepts a time (or a date for cash) or { time:, amount: }.
  # billing_plan: the plan that governs this payment's cycle (a personal plan on a cash payment).
  def apply_payment_updates(payment, updates = {}, billing_plan: nil, first_seen: false)
    paid_at, amount = payment.is_a?(Hash) ? payment.values_at(:time, :amount) : [payment, nil]
    return updates if paid_at.blank?

    paid_on = paid_at.to_date
    updates[:last_payment_date] = paid_on if last_payment_date.nil? || paid_on > last_payment_date

    if payment_in_window?(paid_on, billing_plan) && payment_revives?(paid_at, first_seen: first_seen)
      updates[:membership_state] = 'current_member'
      updates[:membership_ended_date] = nil if membership_ended_date.present?
    end

    maybe_match_plan_from_payment_amount!(updates, amount)
    merge_dues_due_at_after_payment!(updates, paid_on, billing_plan: billing_plan)
    updates
  end

  # A subscription started or resumed after the member cancelled. They are back without a
  # new charge only while their last payment still covers them; a member who already went
  # inactive comes back when the first charge on the new subscription arrives.
  def record_subscription_return!(started_at)
    return false unless effective_membership_state == 'cancelled_member'
    return false unless payment_revives?(started_at, first_seen: true)

    transition_to!('current_member')
  end

  # A cancellation notice, played forward from when it was filed: cancelled while their
  # last payment still covers them, inactive once it does not. Returns :cancelled, :noted
  # (their standing already reflects it; only the date was missing), or :locked.
  def settle_cancellation!(cancelled_at)
    return :locked if membership_state.in?(CANCELLATION_LOCKED_STATES)

    if membership_state.in?(CANCELLATION_SETTLED_STATES)
      note_cancellation!(cancelled_at: cancelled_at)
      return :noted
    end

    self.backdated_membership_state_entered_at = cancelled_at
    return :locked unless record_cancellation!(cancelled_at: cancelled_at)

    MembershipStateResolution::MAX_EXPIRY_HOPS.times { break unless expire_membership_state! }
    :cancelled
  end

  # Where settle_cancellation! would leave a member it moves, without saving.
  def cancellation_landing_state
    paid_through = dues_paid_through_at
    paid_through.present? && paid_through <= Time.current ? 'inactive_member' : 'cancelled_member'
  end

  # The date is kept on its own column as well as in the state, because the fact outlives
  # cancelled_member: once they expire into inactive_member they look exactly like someone
  # who quietly stopped paying, and we would mail them a lapse notice for a decision they
  # made deliberately and already told us about.
  def record_cancellation!(cancelled_at: Time.current)
    return false if terminal_membership_state? || cancelled_member?

    transition_to!('cancelled_member', membership_cancelled_at: cancelled_at)
  end

  def note_cancellation!(cancelled_at: Time.current)
    return false if cancellation_recorded?

    update!(membership_cancelled_at: cancelled_at)
  end

  # Have we processed a cancellation for this member? A return clears the stamp.
  def cancellation_recorded?
    membership_cancelled_at.present?
  end

  # Did this member tell us they were leaving, and stay gone? The question anything about to
  # mail them should ask. The ledger covers a notice nobody has processed yet.
  def cancellation_on_file?
    notice_at = latest_cancellation_at
    return false if notice_at.blank?

    !returned_after?(notice_at)
  end

  def latest_cancellation_at
    [membership_cancelled_at, filed_cancellation_at].compact.max
  end

  def filed_cancellation_at
    payment_events.by_type('subscription_cancelled').maximum(:occurred_at)
  end

  # Evidence the member came back after a moment, by the same line payment_revives? draws:
  # a timed return has to be later, a cash payment dated that day or later counts. The
  # reconciler and the mail guards both ask this, and a return one honours but the other
  # ignores leaves a member deadlocked between them.
  def returned_after?(moment)
    return false if moment.blank?

    last_paid = last_payment_on
    return true if last_paid.present? && last_paid > moment.to_date

    returns = payment_events.where(event_type: RETURN_EVENT_TYPES)
    returns.where.not(source: 'cash').exists?(['payment_events.occurred_at > ?', moment]) ||
      returns.where(source: 'cash').exists?(['payment_events.occurred_at >= ?', moment.in_time_zone.beginning_of_day])
  end

  private

  def record_payment_bookkeeping!(**attrs)
    assign_attributes(attrs)
    save!
    false
  end

  def payment_after?(paid_at, moment)
    return true if moment.blank?
    return paid_at >= moment.to_date if paid_at.instance_of?(Date)

    paid_at > moment
  end

  def before_state_entry?(date)
    entered_on = membership_state_entered_at&.to_date
    entered_on.present? && date < entered_on
  end

  def payment_in_window?(paid_on, billing_plan)
    window = payment_currency_window(billing_plan: billing_plan)
    window.nil? || paid_on >= window.ago.to_date
  end
end
