namespace :membership do
  desc 'Backfill membership_start_date from earliest PayPal payment after Dec 22, 2022'
  task backfill_start_dates: :environment do
    # Cutoff date: Dec 22, 2022
    cutoff_date = Date.new(2022, 12, 22)

    updated_count = 0
    skipped_count = 0
    no_payment_count = 0

    User.find_each do |user|
      # Skip if already has a membership_start_date
      if user.membership_start_date.present?
        skipped_count += 1
        next
      end

      # Find the earliest PayPal payment for this user after the cutoff date
      earliest_payment = user.paypal_payments
                             .where(transaction_time: cutoff_date..)
                             .order(:transaction_time)
                             .first

      if earliest_payment&.transaction_time.present?
        start_date = earliest_payment.transaction_time.to_date
        user.update_column(:membership_start_date, start_date)
        updated_count += 1
        puts "Updated #{user.display_name}: #{start_date}"
      else
        no_payment_count += 1
      end
    end

    puts ''
    puts '=' * 50
    puts 'Backfill complete!'
    puts "  Updated: #{updated_count} users"
    puts "  Skipped (already had date): #{skipped_count} users"
    puts "  No qualifying PayPal payments: #{no_payment_count} users"
  end

  desc 'Preview membership_start_date backfill (dry run)'
  task preview_backfill: :environment do
    cutoff_date = Date.new(2022, 12, 22)

    would_update = []
    already_set = []
    no_payment = []

    User.find_each do |user|
      if user.membership_start_date.present?
        already_set << user
        next
      end

      earliest_payment = user.paypal_payments
                             .where(transaction_time: cutoff_date..)
                             .order(:transaction_time)
                             .first

      if earliest_payment&.transaction_time.present?
        would_update << {
          user: user,
          date: earliest_payment.transaction_time.to_date,
          payment_id: earliest_payment.paypal_id
        }
      else
        no_payment << user
      end
    end

    puts 'DRY RUN - No changes will be made'
    puts '=' * 50
    puts ''

    if would_update.any?
      puts "Would update #{would_update.count} users:"
      would_update.each do |entry|
        puts "  #{entry[:user].display_name} => #{entry[:date]} (from PayPal #{entry[:payment_id]})"
      end
      puts ''
    end

    puts "Already have membership_start_date: #{already_set.count} users"
    puts "No qualifying PayPal payments: #{no_payment.count} users"
    puts ''
    puts "Run 'rake membership:backfill_start_dates' to apply changes."
  end

  desc 'Generate usernames for users without one (firstname + lastname, alphanumeric only)'
  task generate_usernames: :environment do
    puts 'Username Generation'
    puts '=' * 50
    puts ''

    users_without_username = User.where(username: [nil, ''])
    puts "Found #{users_without_username.count} users without usernames"
    puts ''

    updated_count = 0
    skipped_count = 0
    conflict_count = 0

    users_without_username.find_each do |user|
      if user.full_name.blank?
        puts "  Skipped: User ##{user.id} (no full_name)"
        skipped_count += 1
        next
      end

      # Generate base username: lowercase, alphanumeric only
      base_username = user.full_name.downcase
                          .gsub(/[^a-z0-9]/, '') # Remove everything except letters and numbers
                          .truncate(50, omission: '')

      if base_username.blank?
        puts "  Skipped: #{user.full_name} (no valid characters)"
        skipped_count += 1
        next
      end

      # Find a unique username
      candidate = base_username
      counter = 1

      while User.where(username: candidate).where.not(id: user.id).exists?
        candidate = "#{base_username}#{counter}"
        counter += 1
        next unless counter > 100

        puts "  Conflict: #{user.full_name} - too many conflicts for '#{base_username}'"
        conflict_count += 1
        candidate = nil
        break
      end

      next unless candidate

      user.update_column(:username, candidate)
      updated_count += 1
      puts "  Set: #{user.full_name} => #{candidate}"
    end

    puts ''
    puts '=' * 50
    puts 'Summary:'
    puts "  Updated: #{updated_count} users"
    puts "  Skipped (no name): #{skipped_count} users"
    puts "  Conflicts: #{conflict_count} users"
  end

  desc 'Preview username generation (dry run)'
  task preview_usernames: :environment do
    puts 'DRY RUN - No changes will be made'
    puts '=' * 50
    puts ''

    users_without_username = User.where(username: [nil, ''])
    puts "Found #{users_without_username.count} users without usernames"
    puts ''

    would_update = []
    would_skip = []
    would_conflict = []

    users_without_username.find_each do |user|
      if user.full_name.blank?
        would_skip << { user: user, reason: 'no full_name' }
        next
      end

      base_username = user.full_name.downcase
                          .gsub(/[^a-z0-9]/, '')
                          .truncate(50, omission: '')

      if base_username.blank?
        would_skip << { user: user, reason: 'no valid characters' }
        next
      end

      candidate = base_username
      counter = 1

      while User.where(username: candidate).where.not(id: user.id).exists? ||
            would_update.any? { |w| w[:username] == candidate }
        candidate = "#{base_username}#{counter}"
        counter += 1
        next unless counter > 100

        would_conflict << { user: user, base: base_username }
        candidate = nil
        break
      end

      next unless candidate

      would_update << { user: user, username: candidate }
    end

    if would_update.any?
      puts "Would set usernames for #{would_update.count} users:"
      would_update.each { |w| puts "  #{w[:user].full_name} => #{w[:username]}" }
      puts ''
    end

    if would_skip.any?
      puts "Would skip #{would_skip.count} users:"
      would_skip.each { |w| puts "  User ##{w[:user].id}: #{w[:reason]}" }
      puts ''
    end

    if would_conflict.any?
      puts "Would have conflicts for #{would_conflict.count} users:"
      would_conflict.each { |w| puts "  #{w[:user].full_name} (#{w[:base]})" }
      puts ''
    end

    puts "Run 'rake membership:generate_usernames' to apply changes."
  end

  desc 'Non-destructive cleanup of membership, payment, and dues status for all member accounts'
  task cleanup: :environment do
    MembershipCleanup.new(dry_run: false).run
  end

  desc 'Preview membership cleanup (dry run, no changes)'
  task preview_cleanup: :environment do
    MembershipCleanup.new(dry_run: true).run
  end

  desc 'Preview membership state expiries and stale active flags (dry run)'
  task preview_reconcile_active: :environment do
    MembershipActiveReconciler.new(dry_run: true).run
  end

  desc 'Materialize expired membership states and reconcile stale active flags (same as the nightly job)'
  task reconcile_active: :environment do
    Membership::TickJob.perform_now
  end

  desc 'Preview recording of filed subscription cancellations (dry run, no changes)'
  task preview_cancellations: :environment do
    MembershipCancellationReport.new(dry_run: true).run
  end

  desc 'Record filed subscription cancellations and play their timing forward from the cancellation date'
  task process_cancellations: :environment do
    MembershipCancellationReport.new(dry_run: false).run
  end
end
