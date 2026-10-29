namespace :sponsored do
  desc 'Preview which members would be marked as sponsored (dry run)'
  task preview: :environment do
    SponsoredMarker.new(dry_run: true).run
  end

  desc 'Mark members as sponsored based on membership_status or payment_type, then clean up journal entries'
  task mark: :environment do
    SponsoredMarker.new(dry_run: false).run
  end
end

class SponsoredMarker
  def initialize(dry_run: true)
    @dry_run = dry_run
    @marked_count = 0
    @already_sponsored_count = 0
    @skipped_count = 0
    @journal_ids_to_delete = []
  end

  def run
    puts "#{'[DRY RUN] ' if @dry_run}Scanning members for sponsored status..."
    puts

    User.find_each do |user|
      if user.is_sponsored?
        @already_sponsored_count += 1
        next
      end

      if should_mark_sponsored?(user)
        @marked_count += 1
        reason = build_reason(user)
        action = @dry_run ? 'WOULD MARK' : 'MARKING'
        puts "  #{action} sponsored: #{user.display_name} " \
             "(#{user.email || 'no email'}) — #{reason}"

        unless @dry_run
          # Record journal count before update so we can identify the new entry
          journal_count_before = user.journals.count
          unless user.mark_sponsored!
            @marked_count -= 1
            @skipped_count += 1
            next
          end

          # Find and queue the journal entry created by the update for deletion
          new_journals = user.journals.where('id > ?',
                                             user.journals.order(:id).offset(journal_count_before - 1).pick(:id) || 0)
                             .where(action: 'updated')
                             .order(id: :desc)
                             .limit(1)

          new_journals.each do |journal|
            @journal_ids_to_delete << journal.id if journal.changes_json&.key?('is_sponsored')
          end
        end
      else
        @skipped_count += 1
      end
    end

    # Delete the journal entries created by this rake task
    unless @dry_run || @journal_ids_to_delete.empty?
      puts
      puts "Cleaning up #{@journal_ids_to_delete.size} journal entries created by this task..."
      Journal.where(id: @journal_ids_to_delete).delete_all
    end

    puts
    puts 'Summary:'
    puts "  Already sponsored: #{@already_sponsored_count}"
    puts "  #{@dry_run ? 'Would mark' : 'Marked'} as sponsored: #{@marked_count}"
    puts "  Skipped: #{@skipped_count}"
    return unless @journal_ids_to_delete.any? || @dry_run

    puts "  Journal entries #{'would be ' if @dry_run}cleaned up: #{@journal_ids_to_delete.size}"
  end

  private

  def should_mark_sponsored?(user)
    user.membership_status == 'sponsored' || user.payment_type == 'sponsored'
  end

  def build_reason(user)
    parts = []
    parts << 'membership_status: sponsored' if user.membership_status == 'sponsored'
    parts << 'payment_type: sponsored' if user.payment_type == 'sponsored'
    parts.join(', ')
  end
end
