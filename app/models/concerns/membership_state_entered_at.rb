# Stamps membership_state_entered_at on state changes. Expiry-driven materializations
# anchor at the deadline that fired; event-driven transitions (payments, admin moves)
# stamp now.
module MembershipStateEnteredAt
  extend ActiveSupport::Concern

  private

  def stamp_membership_state_entered_at
    return unless will_save_change_to_membership_state? || membership_state_entered_at.blank?

    self.membership_state_entered_at = if expiry_driven_state_change?
                                         resolved_membership_state_entered_at(from_state: membership_state_was)
                                       else
                                         Time.current
                                       end
  end

  def expiry_driven_state_change?
    return false unless will_save_change_to_membership_state?
    return false if membership_state_was.blank?

    entered = membership_state_entered_at_was || created_at || Time.current
    next_state = next_expiry_membership_state(from_state: membership_state_was, entered: entered)
    next_state != membership_state_was && next_state == membership_state
  end

  def resolved_membership_state_entered_at(from_state: membership_state)
    state = from_state
    entered = membership_state_entered_at_for(state)

    MembershipStateResolution::MAX_EXPIRY_HOPS.times do
      deadline = membership_state_deadline(state, entered)
      break if deadline.nil? || deadline > Time.current

      target = MembershipStateResolution::EXPIRY_TARGETS[state]
      break if target.nil? || target == state

      state = target
      entered = deadline
      break if state == membership_state
    end

    entered
  end
end
