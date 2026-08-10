# Operator-facing wrapper around Membership::CancellationReconciler for the
# membership:preview_cancellations / membership:process_cancellations rake tasks.
# rubocop:disable Rails/Output
class MembershipCancellationReport
  def initialize(dry_run:)
    @dry_run = dry_run
  end

  def run
    puts(@dry_run ? 'PREVIEW — no changes will be made' : 'Processing filed subscription cancellations')
    puts '=' * 60

    applied, skipped = Membership::CancellationReconciler.new(dry_run: @dry_run).call.partition(&:applied?)

    print_applied(applied)
    print_skipped(skipped)
    print_summary(applied, skipped)
  end

  private

  def print_applied(applied)
    puts ''
    if applied.empty?
      puts 'No cancellations to record.'
      return
    end

    puts "#{record_verb} #{applied.size} #{'cancellation'.pluralize(applied.size)}:"
    applied.each { |result| puts "  #{applied_line(result)}" }
  end

  def record_verb
    @dry_run ? 'Would record' : 'Recorded'
  end

  def applied_line(result)
    line = "#{result.user.display_name} (id #{result.user.id}): cancelled #{result.cancelled_at.to_date.iso8601}, " \
           "#{result.from_state} -> #{result.to_state}"
    return line if result.withdrawn_reminders.zero?

    verb = @dry_run ? 'would withdraw' : 'withdrew'
    "#{line}, #{verb} #{result.withdrawn_reminders} past-due #{'reminder'.pluralize(result.withdrawn_reminders)}"
  end

  def print_skipped(skipped)
    return if skipped.empty?

    puts ''
    puts "Left alone (#{skipped.size}):"
    skipped.group_by(&:reason).sort_by { |_reason, group| -group.size }.each do |reason, group|
      puts "  #{reason} (#{group.size}):"
      group.each { |result| puts "    #{result.user.display_name} (id #{result.user.id})" }
    end
  end

  def print_summary(applied, skipped)
    withdrawn = applied.sum(&:withdrawn_reminders)
    puts ''
    puts "Cancellations on file: #{applied.size + skipped.size}"
    puts "#{record_verb}: #{applied.size}"
    puts "Left alone: #{skipped.size}"
    puts "Past-due reminders #{@dry_run ? 'to withdraw' : 'withdrawn'}: #{withdrawn}"
    puts ''

    if @dry_run
      puts "Run 'rake membership:process_cancellations' to apply changes." if applied.any?
    else
      puts 'Done.'
    end
  end
end
# rubocop:enable Rails/Output
