# The moves a member can make, and the guard that keeps them legal. Each method names an
# event the organization recognizes — an application approved, a payment linked, a
# cancellation received — rather than a column assignment, so the reason a member's
# standing changed is recoverable from the call site.
module MembershipTransitions
  extend ActiveSupport::Concern

  # Payment events that say a member came back. Recharge opens a fresh subscription rather
  # than reviving the cancelled one, so a later start is a return rather than a duplicate of
  # the notice.
  RETURN_EVENT_TYPES = %w[payment subscription_started subscription_resumed].freeze

  # An approved application makes someone a member immediately, before any payment:
  # they are active while they arrange building access training. Approval is also where
  # the User record is first created, hence 'unknown'. Approving an application for
  # someone who is already a member leaves their standing alone.
  def approve_application!
    return false unless membership_state.in?(%w[unknown inactive_member])

    transition_to!('new_member')
  end

  # Building access training starts the pre-payment grace window.
  def grant_building_access!
    return false unless new_member?

    transition_to!('provisional_member')
  end

  # A linked payment is the only thing that makes someone a current member.
  def record_payment!(**attrs)
    return false if terminal_membership_state?

    transition_to!('current_member', **attrs)
  end

  # A cancellation notice. The member keeps access until their paid-through date;
  # Membership::TickJob moves them to inactive when it passes.
  #
  # The date is kept on its own column as well as in the state, because the fact outlives
  # cancelled_member: once they expire into inactive_member they look exactly like someone
  # who quietly stopped paying, and we would mail them a lapse notice for a decision they
  # made deliberately and already told us about.
  def record_cancellation!(cancelled_at: Time.current)
    return false if terminal_membership_state? || cancelled_member?

    transition_to!('cancelled_member', membership_cancelled_at: cancelled_at)
  end

  # The same fact for a member whose standing has nowhere to go — they lapsed months before
  # anyone processed the notice, or a ban outranks it. Nothing moves; we just stop treating
  # them as someone who forgot to pay.
  def note_cancellation!(cancelled_at: Time.current)
    return false if cancellation_recorded?

    update!(membership_cancelled_at: cancelled_at)
  end

  # Have we processed a cancellation for this member? The stamp is what
  # Membership::CancellationReconciler writes and what a payment clears, so this is the
  # question to ask when deciding whether there is bookkeeping left to do.
  def cancellation_recorded?
    membership_cancelled_at.present?
  end

  # Did this member tell us they were leaving, and stay gone? The broader question, and the
  # one anything about to mail them should ask. The stamp covers cancellations we have
  # processed; the payment event ledger covers a notice nobody has reached yet, or a webhook
  # that went missing after the subscription sync's lookback window closed. True through
  # cancelled_member and onwards into the inactive state it expires to, and false again once
  # anything says they came back.
  def cancellation_on_file?
    notice_at = latest_cancellation_at
    return false if notice_at.blank?

    !returned_after?(notice_at)
  end

  # The most recent word that this member cancelled, from either source.
  def latest_cancellation_at
    [membership_cancelled_at, filed_cancellation_at].compact.max
  end

  # The most recent cancellation notice in the payment event ledger, processed or not.
  def filed_cancellation_at
    payment_events.by_type('subscription_cancelled').maximum(:occurred_at)
  end

  # Evidence the member came back after a given moment. A payment recorded on the row is the
  # obvious one, but the ledger carries returns the columns never hear about: a subscription
  # started or resumed against a member whose last_payment_date nobody updated.
  #
  # Membership::CancellationReconciler asks the same question before deciding to leave a
  # member's standing alone, and the two answers have to match. A return the reconciler
  # honours but the mail guards ignore is a member in a deadlock: the reconciler will not
  # touch their standing because they came back, and the reminders stay switched off because
  # the notice still looks live.
  def returned_after?(moment)
    return false if moment.blank?

    last_paid = last_payment_on
    return true if last_paid.present? && last_paid > moment.to_date

    payment_events.where(event_type: RETURN_EVENT_TYPES)
                  .exists?(['payment_events.occurred_at > ?', moment])
  end

  def ban!
    return false if banned_member?

    transition_to!('banned_member')
  end

  # Whether the guard would accept this move, asked before attempting it. A transition
  # method is a question as much as an order — "can this member be banned?" — so an
  # illegal move comes back as false rather than raising out of save!.
  def can_transition_to?(state)
    return true if allow_any_membership_state_transition

    from = membership_state_was
    return true if from.blank? || from == state

    allowed = MembershipState::TRANSITIONS.fetch(from, [])
    allowed == MembershipState::ANY_STATE || allowed.include?(state)
  end

  # Lifting a ban hands the member back to the clock: their payment history decides
  # where they land.
  def unban!
    return false unless banned_member?

    transition_to!(state_from_payment_history)
  end

  def mark_deceased!
    return false if deceased_member?

    transition_to!('deceased_member', payment_type: 'inactive')
  end

  def mark_sponsored!
    return false if sponsored_member?

    transition_to!('sponsored_member', is_sponsored: true, payment_type: 'sponsored')
  end

  # Sponsorship ends; the member falls back to whatever their payments support.
  def unmark_sponsored!
    return false unless sponsored_member? || is_sponsored?

    fallback_payment_type = payment_type == 'sponsored' ? 'unknown' : payment_type
    transition_to!(state_from_payment_history, is_sponsored: false, payment_type: fallback_payment_type)
  end

  def mark_guest!(duration_months: nil)
    months = duration_months.to_i
    transition_to!('guest_member', dues_due_at: months.positive? ? months.months.from_now : nil)
  end

  # Materializes a deadline that has already passed. Membership::TickJob calls this;
  # every other save picks the same change up through resolve_expired_membership_state.
  def expire_membership_state!
    return false unless membership_state_expired?

    next_state = next_expiry_membership_state
    return false if next_state == membership_state

    transition_to!(next_state)
  end

  # Every transition method funnels through here, so all of them answer an illegal move the
  # same way. Nothing exits deceased_member, and callers ask for moves out of it — a report
  # bulk action, a Recharge cancellation for someone we buried — often enough that raising
  # is the wrong answer.
  def transition_to!(state, **attrs)
    return false unless can_transition_to?(state)

    assign_attributes(attrs.merge(membership_state: state))
    save!
  end

  private

  # Where a member belongs when a ban or sponsorship is lifted and only their payment
  # history is left to go on. Never 'unknown': we know perfectly well what happened to
  # them, and a member with nothing paying for them is inactive.
  def state_from_payment_history
    return 'inactive_member' if last_payment_on.blank?

    paid_through = dues_paid_through_at
    paid_through.nil? || paid_through > Time.current ? 'current_member' : 'inactive_member'
  end
end
