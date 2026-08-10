# `membership_state` is the single source of truth for a member's standing. `active`,
# `membership_status`, and `dues_status` are cached projections of it, rewritten on every
# save so existing queries, reports, and views keep working unchanged.
#
# Callers move members with the transition methods (approve_application!, record_payment!,
# record_cancellation!, ban!, ...) rather than assigning state directly. Assignments are
# checked against TRANSITIONS, so an illegal move fails validation instead of silently
# corrupting a member's standing.
#
# Several states expire on a clock: a grace period runs out, a paid-through date passes.
# MembershipStateResolution applies those deadlines on read, so the projections stay
# correct even before Membership::TickJob materializes the new state into the column.
module MembershipState
  extend ActiveSupport::Concern
  include MembershipStateResolution
  include MembershipStateEnteredAt
  include MembershipStateProjection
  include MembershipTransitions
  include MembershipNotifications

  # No 'applicant': an application is not a member, and only an approved one produces a
  # User at all. Approval creates the record and moves it straight to new_member.
  #
  # 'unknown' is narrower than it looks. It is the bootstrap value and what an
  # unreconciled legacy import sits on; it is not where a member with no payments goes,
  # because that member is plainly inactive rather than mysterious.
  STATES = %w[
    unknown new_member provisional_member current_member overdue_member
    cancelled_member inactive_member guest_member sponsored_member banned_member deceased_member
  ].freeze

  TERMINAL_STATES = %w[banned_member deceased_member].freeze

  # States that grant access, once #effective_membership_state has resolved expiries.
  ACCESS_STATES = %w[
    new_member provisional_member current_member overdue_member cancelled_member
    guest_member sponsored_member
  ].freeze

  # Order the member list filters lead with, roughly "needs attention" before "fine".
  MEMBERSHIP_STATE_FILTER_ORDER = %w[
    new_member provisional_member overdue_member cancelled_member current_member
    sponsored_member guest_member inactive_member banned_member deceased_member unknown
  ].freeze

  # Behind on dues, whether or not they still have access. Excludes bans and deaths,
  # which are not a billing problem.
  LAPSED_STATES = %w[overdue_member inactive_member].freeze

  # Members who are expected to pay and whose payments are up to date.
  PAYING_STATES = %w[new_member provisional_member current_member].freeze

  ANY_STATE = :any

  # Legal moves. Payments and admin actions can arrive at any time, so most states are
  # broadly reachable; the rules worth enforcing are that onboarding runs in order, that
  # deceased is final, and that a ban is only undone by unban!.
  TRANSITIONS = {
    'unknown' => ANY_STATE,
    'new_member' => %w[provisional_member current_member overdue_member cancelled_member
                       inactive_member guest_member sponsored_member banned_member deceased_member],
    'provisional_member' => %w[current_member overdue_member cancelled_member inactive_member
                               sponsored_member banned_member deceased_member],
    'current_member' => %w[overdue_member cancelled_member inactive_member guest_member
                           sponsored_member banned_member deceased_member],
    'overdue_member' => %w[current_member cancelled_member inactive_member guest_member
                           sponsored_member banned_member deceased_member],
    'cancelled_member' => %w[current_member overdue_member inactive_member sponsored_member
                             banned_member deceased_member],
    'inactive_member' => %w[current_member overdue_member new_member guest_member sponsored_member
                            banned_member deceased_member],
    'guest_member' => %w[new_member provisional_member current_member inactive_member
                         sponsored_member banned_member deceased_member],
    'sponsored_member' => %w[current_member overdue_member inactive_member guest_member
                             banned_member deceased_member],
    'banned_member' => %w[unknown inactive_member current_member overdue_member guest_member
                          sponsored_member deceased_member],
    'deceased_member' => []
  }.freeze

  included do
    enum :membership_state, STATES.index_by(&:itself), default: 'unknown', validate: true

    # Set by the admin edit form and by backfills, which may place a member in any state.
    attr_accessor :allow_any_membership_state_transition

    validate :membership_state_transition_is_allowed

    before_save :resolve_expired_membership_state
    before_save :stamp_membership_state_entered_at
    before_save :project_membership_state

    after_update_commit :notify_membership_state_entered

    scope :access_granting, -> { where(membership_state: ACCESS_STATES) }
    scope :in_membership_states, ->(states) { where(membership_state: states) }

    # Read-model scopes. Reports and admin filters ask these questions rather than
    # matching on the projected columns, which cannot express "behind on dues but not
    # banned" without listing exclusions.
    scope :dues_lapsed, -> { where(membership_state: LAPSED_STATES) }
    scope :dues_current, -> { where(membership_state: PAYING_STATES) }
    scope :membership_undetermined, -> { where(membership_state: 'unknown') }
  end

  class_methods do
    # Where to start a member record created without any payment information: someone
    # found on Slack, a name off an unmatched badge scan, the first step of the
    # onboarding wizard.
    #
    # The "Inactive synced as active" switch is the admin saying whether MemberZone's
    # ignorance should cost somebody their access. With it on we extend the benefit of
    # the doubt and give them the onboarding window, which closes on its own after
    # new_member_expiry_days; with it off we say plainly that nothing is paying for them.
    # Either way it is a starting point — a linked payment overrides it immediately.
    def initial_membership_state
      DefaultSetting.instance.authentik_sync_inactive_as_active ? 'new_member' : 'inactive_member'
    end
  end

  def terminal_membership_state?
    TERMINAL_STATES.include?(membership_state)
  end

  # Legacy membership_status predicates, preserved for callers that pre-date the
  # state machine. membership_status itself is a projection; see MEMBERSHIP_STATUS_PROJECTION.
  def paying? = membership_status == 'paying'
  def guest? = guest_member?
  def sponsored? = sponsored_member? || is_sponsored?
  def banned? = banned_member?
  def deceased? = deceased_member?
  def cancelled? = cancelled_member?

  private

  def membership_state_transition_is_allowed
    return unless will_save_change_to_membership_state?
    return if allow_any_membership_state_transition
    return if membership_state_was.blank?

    allowed = TRANSITIONS.fetch(membership_state_was, [])
    return if allowed == ANY_STATE || allowed.include?(membership_state)

    errors.add(:membership_state, "cannot change from #{membership_state_was} to #{membership_state}")
  end
end
