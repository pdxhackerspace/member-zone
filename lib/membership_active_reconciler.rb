# rubocop:disable Rails/Output
class MembershipActiveReconciler
  def initialize(dry_run:, scope: User.non_service_accounts)
    @dry_run = dry_run
    @scope = scope
    @checked = 0
    @stale = []
  end

  def run
    puts(@dry_run ? 'PREVIEW — no changes will be made' : 'Running membership state tick')
    puts '=' * 60

    @scope.find_each do |user|
      @checked += 1
      tick = Membership::StateTick.new(user)
      next unless tick.stale?

      @stale << user
      puts "  #{tick.summary_line}"
      tick.call unless @dry_run
    end

    puts ''
    puts "Checked #{@checked} users"
    puts "Stale: #{@stale.size}"
    if @dry_run
      puts "Run 'rake membership:reconcile_active' to apply changes." if @stale.any?
    else
      puts 'Done.'
    end
  end
end
# rubocop:enable Rails/Output
