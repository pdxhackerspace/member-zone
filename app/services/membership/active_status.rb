module Membership
  # Adapter kept for callers that pre-date the state machine. The rules themselves now
  # live on the User concerns, which recompute the cached columns on every save.
  #
  # Prefer transition methods on User (record_payment!, ban!, record_cancellation!, …)
  # over assign_and_save!; this class exists so bulk tooling and reconciliation scripts
  # keep working while callers migrate.
  class ActiveStatus
    def self.compute(user)
      user.compute_membership_active
    end

    def self.terminal_membership?(user)
      user.terminal_membership_state?
    end

    # In-memory preview of what active would be after projection. Does not save.
    def self.apply_to(user)
      user.active = compute(user)
    end

    def self.needs_reconciliation?(user)
      return false if user.service_account?

      user.read_attribute(:active) != compute(user) || user.membership_state_expired?
    end

    def self.reconcile!(user)
      return false unless needs_reconciliation?(user)

      user.save!
      true
    end

    # Record a linked payment and let User decide whether it still covers the member.
    # Skips payment-immune states (cancelled, banned, deceased, sponsored).
    def self.record_linked_payment!(user, **attrs)
      return false if user.membership_state.in?(User::PAYMENT_IMMUNE_STATES)

      user.record_payment!(**attrs)
    end

    # Bulk tools and backfills. Non-state attributes save normally; a membership_state
    # assignment lifts the transition guard first so destructive rake tasks can reset rows.
    def self.assign_and_save!(user, attrs)
      attrs = attrs.symbolize_keys
      state = attrs.delete(:membership_state)
      user.allow_any_membership_state_transition = true if state
      attrs.each { |key, value| user.public_send(:"#{key}=", value) }
      user.membership_state = state if state
      user.save!
    ensure
      user.allow_any_membership_state_transition = false if state
    end
  end
end
