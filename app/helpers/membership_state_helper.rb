# How a membership state is written and coloured. Colour is reserved for states an admin
# might need to do something about; the ordinary case is left neutral.
module MembershipStateHelper
  # Reads better than humanize, which would render "New member" and "Provisional member"
  # without saying what distinguishes them.
  MEMBERSHIP_STATE_LABELS = {
    'new_member' => 'New member',
    'provisional_member' => 'In grace period',
    'current_member' => 'Current',
    'overdue_member' => 'Overdue',
    'cancelled_member' => 'Cancelled',
    'inactive_member' => 'Inactive',
    'guest_member' => 'Guest',
    'sponsored_member' => 'Sponsored',
    'banned_member' => 'Banned',
    'deceased_member' => 'Deceased'
  }.freeze

  ATTENTION_STATES = %w[overdue_member cancelled_member].freeze
  ACTIVE_STATES = %w[current_member sponsored_member new_member provisional_member guest_member].freeze

  def membership_state_label(state)
    MEMBERSHIP_STATE_LABELS.fetch(state.to_s, state.to_s.humanize)
  end

  def membership_state_dot_class(state)
    case state.to_s
    when *ACTIVE_STATES then 'status-success'
    when *ATTENTION_STATES then 'status-warning'
    when 'banned_member', 'deceased_member' then 'status-danger'
    else 'status-muted'
    end
  end

  def membership_state_badge_subtle_class(state)
    case state.to_s
    when 'current_member' then 'text-bg-success-subtle'
    when 'sponsored_member', 'new_member', 'provisional_member' then 'text-bg-info-subtle'
    when *ATTENTION_STATES, 'guest_member' then 'text-bg-warning-subtle'
    when 'banned_member' then 'text-bg-danger-subtle'
    when 'deceased_member' then 'text-bg-dark-subtle'
    else 'text-bg-secondary-subtle'
    end
  end

  # Colour on a filter chip means the count is something an admin should look at.
  def membership_state_filter_chip_class(state)
    case state.to_s
    when *ATTENTION_STATES then 'warning'
    when 'banned_member' then 'danger'
    else ''
    end
  end

  # The pill beside a member's name in the admin hero: whether they get in, and why not.
  def member_admin_status_pill(user)
    case user.effective_membership_state
    when 'banned_member', 'deceased_member', 'inactive_member' then %w[Inactive status-pill-overdue]
    when 'overdue_member' then ['Payment due', 'status-pill-attention']
    when 'cancelled_member' then %w[Cancelled status-pill-attention]
    else user.active? ? %w[Active status-pill-active] : %w[Inactive status-pill-overdue]
    end
  end

  # The member's own view of their standing: friendly wording, and no distinction drawn
  # between the several ways a membership can end.
  def member_membership_card_status(user)
    case user.effective_membership_state
    when 'current_member' then ['Active', 'status-pill-active', '']
    when 'sponsored_member' then ['Sponsored', 'status-pill-active', '']
    when 'guest_member' then ['Guest', 'status-pill-active', '']
    when 'new_member', 'provisional_member' then ['Getting started', 'status-pill-active', '']
    when 'overdue_member' then ['Payment due', 'status-pill-attention', 'status-attention']
    when 'cancelled_member' then %w[Cancelled status-pill-attention status-attention]
    else %w[Inactive status-pill-overdue status-overdue]
    end
  end
end
