namespace :membership do
  desc 'Preview fixing unknown membership statuses'
  task preview_status_fix: :environment do
    MembershipStatusFixer.new(dry_run: true).run
  end

  desc 'Fix unknown membership statuses'
  task fix_status: :environment do
    MembershipStatusFixer.new(dry_run: false).run
  end
end

class MembershipStatusFixer
  def initialize(dry_run: true)
    @dry_run = dry_run
    @plans = MembershipPlan.primary.to_a
    @unknown_to_paying = []
    @unknown_to_lapsed = []
    @unknown_no_payments = 0
    @unknown_skipped = 0
  end

  def run
    puts "#{'[DRY RUN] ' if @dry_run}Membership Status Fix"
    puts '=' * 60
    puts
    puts 'Membership plans:'
    @plans.each { |p| puts "  - #{p.name}: $#{format('%.2f', p.cost)} (#{p.billing_frequency})" }
    puts

    fix_unknown_statuses

    puts
    puts '=' * 60
    puts 'Summary:'
    puts "  Unknown -> Paying:  #{@unknown_to_paying.size}"
    puts "  Unknown -> Lapsed:  #{@unknown_to_lapsed.size}"
    puts "  Unknown with no payments: #{@unknown_no_payments}"
    puts "  Unknown skipped (service/legacy): #{@unknown_skipped}"
    puts
    puts @dry_run ? "Run 'rake membership:fix_status' to apply changes." : 'Done!'
  end

  private

  def fix_unknown_statuses
    puts '--- Fixing Unknown Membership Status ---'
    puts

    User.where(membership_status: 'unknown').find_each do |user|
      if user.service_account? || user.legacy?
        @unknown_skipped += 1
        next
      end

      payments = collect_payments(user)
      if payments.empty?
        @unknown_no_payments += 1
        next
      end

      latest = payments.last
      effective_plan = user.membership_plan || match_plan(latest[:amount])
      cutoff = MembershipTaskHelpers.cutoff_for_plan(effective_plan)
      plan_label = if effective_plan
                     "#{effective_plan.name} (#{effective_plan.billing_frequency})"
                   else
                     'no plan (monthly default)'
                   end

      if latest[:time] >= cutoff
        @unknown_to_paying << user
        action = @dry_run ? 'WOULD SET' : 'SETTING'
        puts "  #{action} #{user.display_name}: unknown -> paying, " \
             "dues: current [#{plan_label}, last payment: #{latest[:time].to_date}]"
        unless @dry_run
          attrs = { membership_status: 'paying', dues_status: 'current' }
          attrs[:membership_plan_id] = effective_plan.id if effective_plan && user.membership_plan_id.blank?
          attrs.each { |k, v| user.send(:"#{k}=", v) }
          user.save!
        end
      else
        @unknown_to_lapsed << user
        action = @dry_run ? 'WOULD SET' : 'SETTING'
        puts "  #{action} #{user.display_name}: unknown -> paying (lapsed), " \
             "dues: lapsed [#{plan_label}, last payment: #{latest[:time].to_date}]"
        unless @dry_run
          attrs = { membership_status: 'paying', dues_status: 'lapsed' }
          attrs[:membership_plan_id] = effective_plan.id if effective_plan && user.membership_plan_id.blank?
          attrs.each { |k, v| user.send(:"#{k}=", v) }
          user.save!
        end
      end
    end

    puts
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

  def match_plan(amount)
    return nil if amount.blank?

    MembershipTaskHelpers.find_matching_plan(@plans, amount)
  end
end
