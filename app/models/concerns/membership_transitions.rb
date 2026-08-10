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

  # A linked payment is the only thing that makes someone a current member.
  def record_payment!(**attrs)
    return false if terminal_membership_state?

    transition_to!('current_member', **attrs)
  end

  # A cancellation notice. The member keeps access until their paid-through date;
  # Membership::TickJob moves them to inactive when it passes.
  def record_cancellation!
    return false if terminal_membership_state? || cancelled_member?

    transition_to!('cancelled_member')
  end

  def ban!
    return false if banned_member?

    transition_to!('banned_member')
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

    transition_to!(effective_membership_state)
  end

  def transition_to!(state, **attrs)
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
