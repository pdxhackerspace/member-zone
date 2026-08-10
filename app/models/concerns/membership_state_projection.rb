# The cached columns the rest of the app still reads. `active`, `membership_status`, and
# `dues_status` are rewritten from membership_state on every save, so a query written
# before the state machine existed keeps returning what it always returned.
#
# Nothing should assign these columns directly — they are overwritten on the next save.
module MembershipStateProjection
  extend ActiveSupport::Concern

  # Legacy `membership_status` values, kept as a projection so existing reports and views
  # keep reading what they always read. Members behind on dues stay 'paying' and are
  # distinguished by dues_status, matching the pre-state-machine behaviour.
  MEMBERSHIP_STATUS_PROJECTION = {
    'unknown' => 'unknown',
    'new_member' => 'paying',
    'provisional_member' => 'paying',
    'current_member' => 'paying',
    'overdue_member' => 'paying',
    'cancelled_member' => 'cancelled',
    'inactive_member' => 'paying',
    'guest_member' => 'guest',
    'sponsored_member' => 'sponsored',
    'banned_member' => 'banned',
    'deceased_member' => 'deceased'
  }.freeze

  DUES_STATUS_PROJECTION = {
    'unknown' => 'unknown',
    'new_member' => 'current',
    'provisional_member' => 'current',
    'current_member' => 'current',
    'overdue_member' => 'lapsed',
    'cancelled_member' => 'current',
    'inactive_member' => 'lapsed',
    'guest_member' => 'current',
    'sponsored_member' => 'current',
    'banned_member' => 'inactive',
    'deceased_member' => 'inactive'
  }.freeze

  # States that settle the question of how someone pays. A sponsored member is not
  # missing a payment type — somebody else covers them, and 'sponsored' says so; the
  # dead are not expected to pay at all. Every other state leaves payment_type alone,
  # since it records a real payment channel we learned from a payment.
  PAYMENT_TYPE_PROJECTION = {
    'sponsored_member' => 'sponsored',
    'deceased_member' => 'inactive'
  }.freeze

  # Whether this member should have access, given their state and any override.
  # Service accounts are managed by hand and keep whatever they were given.
  def compute_membership_active
    return self[:active] if service_account?

    state = effective_membership_state
    return false if MembershipState::TERMINAL_STATES.include?(state)
    return true if emergency_active_override?

    MembershipState::ACCESS_STATES.include?(state)
  end

  # The cached `active` column is for queries and reports; this resolves deadlines on
  # read so access stays correct between nightly runs of Membership::TickJob.
  def active?
    compute_membership_active
  end

  private

  # Rewrites the cached columns that the rest of the app reads.
  def project_membership_state
    self.active = compute_membership_active
    return if service_account?

    self.membership_status = MEMBERSHIP_STATUS_PROJECTION.fetch(membership_state, 'unknown')
    self.dues_status = DUES_STATUS_PROJECTION.fetch(membership_state, 'unknown')
    dictated_payment_type = PAYMENT_TYPE_PROJECTION[membership_state]
    self.payment_type = dictated_payment_type if dictated_payment_type
  end
end
