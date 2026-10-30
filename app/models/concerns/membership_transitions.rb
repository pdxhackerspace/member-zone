# The moves a member can make, and the guard that keeps them legal. Each method names an
# event the organization recognizes — an application approved, a payment linked, a
# cancellation received — rather than a column assignment, so the reason a member's
# standing changed is recoverable from the call site.
module MembershipTransitions
  extend ActiveSupport::Concern

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
  #
  # Reads the grace-adjusted deadline rather than the paid-through date so that lifting a
  # ban on the day someone's dues fall due gives them the same benefit of the doubt the
  # clock would have given them, instead of filing them as lapsed on the spot.
  def state_from_payment_history
    return 'inactive_member' if last_payment_on.blank?

    grace_ends_at = dues_grace_ends_at
    grace_ends_at.nil? || grace_ends_at > Time.current ? 'current_member' : 'inactive_member'
  end
end
