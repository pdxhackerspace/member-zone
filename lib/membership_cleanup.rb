# frozen_string_literal: true

# Encapsulate cleanup logic for rake tasks membership:cleanup / preview_cleanup.
# rubocop:disable Rails/Output, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
# STDOUT is deliberate for operator-facing rake output; complexity mirrors legacy rake definition.
class MembershipCleanup
  def initialize(dry_run:)
    @dry_run = dry_run
    @plans = MembershipPlan.primary.to_a
    @changes = { plan_matched: [], payment_type_set: [], marked_paying: [],
                 marked_lapsed: [], marked_inactive: [], marked_sponsored_active: [],
                 skipped_service: [], no_change: [] }
  end

  def run
    puts @dry_run ? 'PREVIEW — no changes will be made' : 'Membership Cleanup'
    puts '=' * 60
    puts ''
    puts 'Membership plans available for matching:'
    @plans.each { |p| puts "  - #{p.name}: $#{format('%.2f', p.cost)} (#{p.billing_frequency})" }
    puts ''

    User.non_service_accounts.includes(:paypal_payments, :recharge_payments, :sheet_entry, :membership_plan)
        .find_each do |user|
      process_user(user)
    end

    skipped = User.service_accounts.count
    puts ''
    puts "Skipped #{skipped} service accounts"
    puts ''
    print_summary
    puts ''
    puts @dry_run ? "Run 'rake membership:cleanup' to apply these changes." : 'Done!'
  end

  private

  def process_user(user)
    actions = []

    all_payments = collect_payments(user)
    latest = all_payments.last

    # 1. Sponsored users — always active (check is_sponsored flag, membership state, payment type, or sheet entry).
    # An inactive sponsored member is drift: nothing about a sponsorship expires on its own.
    if sponsored?(user)
      if !user.sponsored_member?
        apply { user.mark_sponsored! }
        actions << 'set sponsored/active'
        @changes[:marked_sponsored_active] << user
      elsif user.payment_type != 'sponsored' || !user.active?
        apply { user.update!(payment_type: 'sponsored', is_sponsored: true) }
        actions << 'set sponsored/active'
        @changes[:marked_sponsored_active] << user
      end
      @changes[:no_change] << user if actions.empty?
      return
    end

    # 2. No payments and not sponsored → inactive. Members who never got as far as a
    # payment are left where they are; there is nothing to reconcile against.
    if all_payments.empty?
      if user.membership_state.in?(%w[current_member overdue_member provisional_member])
        apply { Membership::ActiveStatus.assign_and_save!(user, membership_state: 'inactive_member') }
        actions << 'no payments → inactive'
        @changes[:marked_inactive] << user
      end
      @changes[:no_change] << user if actions.empty?
      return
    end

    # 3. Has payments — match plan if missing
    if user.membership_plan_id.blank? && latest[:amount].present?
      matched = MembershipTaskHelpers.find_matching_plan(@plans, latest[:amount])
      if matched
        apply { user.update!(membership_plan_id: matched.id) }
        actions << "matched plan: #{matched.name}"
        @changes[:plan_matched] << { user: user, plan: matched }
      end
    end

    # Determine effective plan (may have just been set, or was already present)
    effective_plan = if user.membership_plan_id.present?
                       user.membership_plan || MembershipPlan.find_by(id: user.membership_plan_id)
                     elsif latest[:amount].present?
                       MembershipTaskHelpers.find_matching_plan(@plans, latest[:amount])
                     end

    # 4. Has payments but no payment_type → set from payment source
    if %w[unknown inactive].include?(user.payment_type)
      apply { user.update!(payment_type: latest[:type]) }
      actions << "payment_type → #{latest[:type]}"
      @changes[:payment_type_set] << { user: user, type: latest[:type] }
    end

    # 5. Record the payment and let User decide whether it still covers them.
    record_latest_payment(user, latest, effective_plan, actions)

    if actions.any?
      plan_label = if effective_plan
                     "#{effective_plan.name} (#{effective_plan.billing_frequency})"
                   else
                     'no plan (monthly default)'
                   end
      puts "  #{user.display_name}: #{actions.join(', ')} [#{plan_label}]"
    else
      @changes[:no_change] << user
    end
  end

  def record_latest_payment(user, latest, effective_plan, actions)
    return if user.membership_state.in?(User::PAYMENT_IMMUNE_STATES)

    attrs = {
      last_payment_date: latest[:time].to_date,
      dues_due_at: User.dues_due_at_from_payment_cycle(latest[:time].to_date, effective_plan)
    }

    if @dry_run
      user.assign_attributes(attrs.merge(membership_state: 'current_member'))
      return unless user.changed?

      target = user.effective_membership_state
    else
      Membership::ActiveStatus.record_linked_payment!(user, **attrs)
      target = user.membership_state
    end

    if target == 'current_member'
      actions << 'paying + current'
      @changes[:marked_paying] << user
    else
      actions << "#{target.humanize.downcase} (last payment #{latest[:time].to_date})"
      @changes[:marked_lapsed] << user
    end
  end

  def collect_payments(user)
    payments = []
    user.paypal_payments.each do |p|
      next if p.transaction_time.blank?

      payments << { time: p.transaction_time, amount: p.amount, type: 'paypal' }
    end
    user.recharge_payments.each do |p|
      next if p.processed_at.blank?

      payments << { time: p.processed_at, amount: p.amount, type: 'recharge' }
    end
    KofiPayment.where(user_id: user.id).find_each do |p|
      next if p.timestamp.blank?

      payments << { time: p.timestamp, amount: p.amount, type: 'kofi' }
    end
    payments.sort_by { |p| p[:time] }
  end

  def apply
    return if @dry_run

    yield
  end

  def sponsored?(user)
    user.sponsored? || user.payment_type == 'sponsored' ||
      user.sheet_entry&.status.to_s.downcase.include?('sponsored')
  end

  def print_summary
    puts '=' * 60
    puts 'Summary:'
    puts "  Plan matched:           #{@changes[:plan_matched].size}"
    @changes[:plan_matched].each { |h| puts "    #{h[:user].display_name} → #{h[:plan].name}" }
    puts "  Payment type set:       #{@changes[:payment_type_set].size}"
    @changes[:payment_type_set].each { |h| puts "    #{h[:user].display_name} → #{h[:type]}" }
    puts "  Marked paying+current:  #{@changes[:marked_paying].size}"
    puts "  Marked lapsed:          #{@changes[:marked_lapsed].size}"
    @changes[:marked_lapsed].each { |u| puts "    #{u.display_name}" }
    puts "  Marked inactive:        #{@changes[:marked_inactive].size}"
    @changes[:marked_inactive].first(20).each { |u| puts "    #{u.display_name}" }
    puts "    ... and #{@changes[:marked_inactive].size - 20} more" if @changes[:marked_inactive].size > 20
    puts "  Confirmed sponsored:    #{@changes[:marked_sponsored_active].size}"
    puts "  No change needed:       #{@changes[:no_change].size}"
  end
end
# rubocop:enable Rails/Output, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
