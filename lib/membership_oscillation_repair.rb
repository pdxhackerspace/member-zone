# Repairs members whose standing was flipped by a payment sync re-reading an old charge
# and a subscription sync re-applying a cancellation already on file. Dry-run twin:
# rake membership:repair_oscillation_preview.
#
# Leaves the journals in place. They are the evidence the flip happened.
# STDOUT is deliberate for operator-facing rake output, matching MembershipCleanup.
class MembershipOscillationRepair
  # rubocop:disable Rails/Output
  LOOKBACK = 60.days
  DUPLICATE_MAIL_ACTIONS = %w[membership_cancelled membership_lapsed membership_sponsored].freeze
  WITHDRAWABLE_STATUSES = %w[pending approved].freeze

  def initialize(dry_run:)
    @dry_run = dry_run
    @repaired = []
    @sponsored = []
    @mail_withdrawn = 0
  end

  def run
    puts @dry_run ? 'PREVIEW — no changes will be made' : 'Repair membership state oscillation'
    puts '=' * 60

    cancellation_candidates.each { |user| repair_cancellation(user) }
    sponsored_candidates.each { |user| repair_sponsorship(user) }

    print_summary
  end

  private

  def cancellation_candidates
    users_for_flips('inactive_member').select { |user| cancellation_needs_repair?(user) }
  end

  def sponsored_candidates
    users_for_flips('sponsored_member').select { |user| sponsorship_needs_repair?(user) }
  end

  def users_for_flips(from_state)
    ids = system_flips_to_current(from_state).distinct.pluck(:user_id)
    User.where(id: ids).to_a
  end

  def system_flips_to_current(from_state)
    Journal.where(actor_user_id: nil)
           .where(changed_at: LOOKBACK.ago..)
           .where("changes_json #>> '{membership_state,from}' = ?", from_state)
           .where("changes_json #>> '{membership_state,to}' = ?", 'current_member')
  end

  def cancellation_needs_repair?(user)
    return false if user.membership_state.in?(%w[banned_member deceased_member sponsored_member guest_member])

    cancelled_at = user.filed_cancellation_at
    return false if cancelled_at.blank? || user.returned_after?(cancelled_at)

    target = state_after_cancellation(user)
    user.membership_state != target || user.membership_cancelled_at.blank? ||
      user.membership_cancelled_at < cancelled_at
  end

  def sponsorship_needs_repair?(user)
    return false if user.sponsored_member? || user.terminal_membership_state?
    return false unless user.current_member?

    latest_exit = Journal.where(user_id: user.id)
                         .where("changes_json #>> '{membership_state,from}' = ?", 'sponsored_member')
                         .order(changed_at: :desc)
                         .first
    latest_exit&.actor_user_id.nil?
  end

  def state_after_cancellation(user)
    paid_through = user.dues_paid_through_at
    paid_through.present? && paid_through <= Time.current ? 'inactive_member' : 'cancelled_member'
  end

  def repair_cancellation(user)
    cancelled_at = user.filed_cancellation_at
    target = state_after_cancellation(user)
    puts "  #{user.display_name}: #{user.membership_state} -> #{target}, " \
         "cancellation #{cancelled_at.to_date}"
    @repaired << user
    withdraw_duplicate_mail(user)
    return if @dry_run

    with_quiet_saves { apply_cancellation!(user, cancelled_at) }
    push_to_authentik(user)
  end

  def apply_cancellation!(user, cancelled_at)
    user.backdated_membership_state_entered_at = cancelled_at
    moved = user.record_cancellation!(cancelled_at: cancelled_at)
    force_cancelled!(user, cancelled_at) unless moved
    play_forward(user)
  end

  def force_cancelled!(user, cancelled_at)
    user.allow_any_membership_state_transition = true
    user.backdated_membership_state_entered_at = cancelled_at
    user.update!(membership_state: 'cancelled_member', membership_cancelled_at: cancelled_at)
  ensure
    user.allow_any_membership_state_transition = false
  end

  def play_forward(user)
    MembershipStateResolution::MAX_EXPIRY_HOPS.times do
      break unless user.expire_membership_state!
    end
  end

  def repair_sponsorship(user)
    puts "  #{user.display_name}: #{user.membership_state} -> sponsored_member"
    @sponsored << user
    withdraw_duplicate_mail(user)
    return if @dry_run

    with_quiet_saves { user.mark_sponsored! }
    push_to_authentik(user)
  end

  def with_quiet_saves(&)
    Current.set(skip_membership_state_email: true, skip_authentik_sync: true, &)
  end

  def withdraw_duplicate_mail(user)
    DUPLICATE_MAIL_ACTIONS.each do |action|
      mails = user.queued_mails.where(mailer_action: action, status: WITHDRAWABLE_STATUSES, sent_at: nil)
                  .order(:created_at).to_a
      mails.drop(1).each do |mail|
        mail.reject!(nil) unless @dry_run
        @mail_withdrawn += 1
      end
    end
  end

  def push_to_authentik(user)
    return if user.authentik_id.blank?

    Authentik::UserSyncJob.perform_later(user.id)
  end

  def print_summary
    puts
    puts "  Cancellation repairs: #{@repaired.size}"
    @repaired.each { |user| puts "    #{user.display_name}" }
    puts "  Sponsorship repairs:  #{@sponsored.size}"
    @sponsored.each { |user| puts "    #{user.display_name}" }
    puts "  Duplicate mail withdrawn: #{@mail_withdrawn}"
    puts
    puts @dry_run ? "Run 'rake membership:repair_oscillation' to apply these changes." : 'Done!'
  end
  # rubocop:enable Rails/Output
end
