# Turns the stored membership_state into the state a member is actually in right now,
# and writes the cached columns the rest of the app reads.
#
# Three states end on a deadline rather than on an event: a new member who never trains,
# a grace period that runs out, a paid-through date that passes. Resolving those on read
# keeps `active` honest between runs of Membership::TickJob, which would otherwise be the
# only thing standing between a lapsed member and an open door.
module MembershipStateResolution
  extend ActiveSupport::Concern

  # Where a state lands when its deadline passes. Applied repeatedly, so a provisional
  # member whose grace ran out months ago resolves through overdue to inactive in one pass.
  EXPIRY_TARGETS = {
    'new_member' => 'inactive_member',
    'provisional_member' => 'overdue_member',
    'current_member' => 'overdue_member',
    'overdue_member' => 'inactive_member',
    'cancelled_member' => 'inactive_member',
    'guest_member' => 'inactive_member'
  }.freeze

  # Stops a cycle in EXPIRY_TARGETS from turning resolution into an infinite loop.
  MAX_EXPIRY_HOPS = 4

  # The state this member should be in right now, with elapsed deadlines applied.
  def effective_membership_state
    state = membership_state
    entered = membership_state_anchor

    MAX_EXPIRY_HOPS.times do
      deadline = membership_state_deadline(state, entered)
      break if deadline.nil? || deadline > Time.current

      target = EXPIRY_TARGETS[state]
      break if target.nil? || target == state

      state = target
      entered = deadline
    end

    state
  end

  def membership_state_expired?
    effective_membership_state != membership_state
  end

  # The next state after one elapsed deadline — what materialization should persist per
  # save or tick. Read-time resolution still chains through effective_membership_state.
  def next_expiry_membership_state(from_state: membership_state, entered: nil)
    entered ||= membership_state_entered_at_for(from_state)
    deadline = membership_state_deadline(from_state, entered)
    return from_state if deadline.nil? || deadline > Time.current

    target = EXPIRY_TARGETS[from_state]
    return from_state if target.nil? || target == from_state

    target
  end

  # When the current state runs out, or nil if nothing is counting down.
  def membership_state_expires_at
    membership_state_deadline(membership_state, membership_state_anchor)
  end

  # The date a member's current payment covers them through. Falls back to the last
  # payment plus the plan's billing window for members with no plan, so overdue and
  # cancelled-until-paid-through are defined for them too. Nil means nothing is counting
  # down: a one-time plan, or no payment history to measure from.
  def dues_paid_through_at
    return dues_due_at if dues_due_at.present?

    window = payment_currency_window
    return nil if window.nil?

    anchor = last_payment_on
    return nil if anchor.blank?

    (anchor + window).in_time_zone.beginning_of_day
  end

  # Most recent payment using only columns on this row, so it is safe to call during a
  # save. #most_recent_payment_date queries the payment tables and is not.
  def last_payment_on
    [last_payment_date, recharge_most_recent_payment_date&.to_date].compact.max
  end

  private

  def membership_state_entered_at_for(state)
    if state == membership_state_was
      membership_state_entered_at_was || created_at || Time.current
    else
      membership_state_anchor
    end
  end

  def membership_state_deadline(state, entered)
    case state
    when 'new_member' then entered + MembershipSetting.new_member_expiry_days.days
    when 'provisional_member' then entered + MembershipSetting.new_member_grace_period_days.days
    when 'overdue_member' then entered + MembershipSetting.overdue_grace_period_days.days
    when 'current_member', 'cancelled_member', 'guest_member' then dues_paid_through_at
    end
  end

  def membership_state_anchor
    membership_state_entered_at || created_at || Time.current
  end

  def resolve_expired_membership_state
    return if service_account?

    if new_record?
      from_state = membership_state
      next_state = next_expiry_membership_state(from_state: from_state)
      if next_state != from_state
        self.expiry_materialized_from_state = from_state
        self.membership_state = next_state
      end
      return
    end

    return if membership_state_was != membership_state

    next_state = next_expiry_membership_state(
      from_state: membership_state_was,
      entered: membership_state_entered_at_was || created_at || Time.current
    )
    self.membership_state = next_state if next_state != membership_state
  end
end
