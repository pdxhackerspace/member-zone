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

    results = Membership::CancellationReconciler.new(dry_run: @dry_run).call
    @applied = results.select(&:applied?)
    @noted = results.select(&:noted?)
    @skipped = results.select(&:skipped?)

    print_applied
    print_noted
    print_skipped
    print_summary
  end

  private

  def print_applied
    puts ''
    if @applied.empty?
      puts 'No memberships to move.'
      return
    end

    puts "#{record_verb} #{@applied.size} #{'cancellation'.pluralize(@applied.size)}:"
    @applied.each { |result| puts "  #{applied_line(result)}" }
  end

  # Already where the cancellation would have left them, so all that was missing was the
  # reason — which is what keeps the lapsed email away from them.
  def print_noted
    return if @noted.empty?

    puts ''
    puts "#{record_verb} the cancellation date for #{@noted.size} already-settled #{'member'.pluralize(@noted.size)}:"
    @noted.each do |result|
      puts "  #{result.user.display_name} (id #{result.user.id}): cancelled #{date_of(result)}, " \
           "already #{result.to_state}"
    end
  end

  def print_skipped
    return if @skipped.empty?

    puts ''
    puts "Left alone (#{@skipped.size}):"
    @skipped.group_by(&:reason).sort_by { |_reason, group| -group.size }.each do |reason, group|
      puts "  #{reason} (#{group.size}):"
      group.each { |result| puts "    #{result.user.display_name} (id #{result.user.id})#{reminder_note(result)}" }
    end
  end

  # Their standing did not change, but their past-due mail still did.
  def reminder_note(result)
    return '' if result.withdrawn_reminders.zero?

    verb = @dry_run ? 'would withdraw' : 'withdrew'
    " — #{verb} #{result.withdrawn_reminders} past-due #{'reminder'.pluralize(result.withdrawn_reminders)}"
  end

  def print_summary
    withdrawn = (@applied + @noted + @skipped).sum(&:withdrawn_reminders)
    puts ''
    puts "Cancellations on file: #{@applied.size + @noted.size + @skipped.size}"
    puts "#{@dry_run ? 'Would move' : 'Moved'}: #{@applied.size}"
    puts "#{@dry_run ? 'Would date only' : 'Dated only'}: #{@noted.size}"
    puts "Left alone: #{@skipped.size}"
    puts "Past-due reminders #{@dry_run ? 'to withdraw' : 'withdrawn'}: #{withdrawn}"
    puts ''

    if @dry_run
      changes = @applied.any? || @noted.any? || withdrawn.positive?
      puts "Run 'rake membership:process_cancellations' to apply changes." if changes
    else
      puts 'Done.'
    end
  end

  def record_verb
    @dry_run ? 'Would record' : 'Recorded'
  end

  def applied_line(result)
    line = "#{result.user.display_name} (id #{result.user.id}): cancelled #{date_of(result)}, " \
           "#{result.from_state} -> #{result.to_state}"
    return line if result.withdrawn_reminders.zero?

    verb = @dry_run ? 'would withdraw' : 'withdrew'
    "#{line}, #{verb} #{result.withdrawn_reminders} past-due #{'reminder'.pluralize(result.withdrawn_reminders)}"
  end

  def date_of(result)
    result.cancelled_at.to_date.iso8601
  end
end
# rubocop:enable Rails/Output
