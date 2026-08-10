namespace :payments do
  desc 'Set user_id on PayPal and Recharge payments based on payer/customer ID matches, and set membership dates'
  task link: :environment do
    puts '=' * 60
    puts 'Linking payments to users'
    puts '=' * 60

    # Build lookup hashes for efficiency
    puts "\nBuilding user lookup tables..."

    # PayPal: user.paypal_account_id => user.id
    paypal_user_map = User.where.not(paypal_account_id: [nil, ''])
                          .pluck(:paypal_account_id, :id)
                          .to_h
    puts "  Found #{paypal_user_map.size} users with PayPal account IDs"

    # Recharge: user.recharge_customer_id => user.id
    recharge_user_map = User.where.not(recharge_customer_id: [nil, ''])
                            .pluck(:recharge_customer_id, :id)
                            .to_h
    puts "  Found #{recharge_user_map.size} users with Recharge customer IDs"

    # Process PayPal payments
    puts "\n#{'-' * 60}"
    puts 'Processing PayPal payments...'

    paypal_by_payer_id = 0
    paypal_by_email = 0
    paypal_by_name = 0
    paypal_no_match = 0

    # Build email lookup: lowercase email => user
    email_to_user = {}
    User.find_each do |user|
      email_to_user[user.email.to_s.strip.downcase] = user if user.email.present?
      (user.extra_emails || []).each do |extra|
        email_to_user[extra.to_s.strip.downcase] = user if extra.present?
      end
    end

    # Build name lookup: lowercase full_name => user
    name_to_user = {}
    User.where.not(full_name: [nil, '']).find_each do |user|
      name_to_user[user.full_name.strip.downcase] = user
    end

    PaypalPayment.matching_plan.where(user_id: nil).find_each do |payment|
      user = nil
      match_type = nil

      # 1. Try to match by payer_id
      if payment.payer_id.present?
        user_id = paypal_user_map[payment.payer_id]
        if user_id
          user = User.find_by(id: user_id)
          match_type = :payer_id
        end
      end

      # 2. Try to match by email
      if user.nil? && payment.payer_email.present?
        normalized_email = payment.payer_email.strip.downcase
        user = email_to_user[normalized_email]
        match_type = :email if user
      end

      # 3. Try to match by name
      if user.nil? && payment.payer_name.present?
        normalized_name = payment.payer_name.strip.downcase
        user = name_to_user[normalized_name]
        match_type = :name if user
      end

      if user
        # Link the payment to the user
        payment.update_column(:user_id, user.id)

        # If matched by email or name, also set the paypal_account_id on the user
        if match_type != :payer_id && payment.payer_id.present? && user.paypal_account_id.blank?
          user.update_column(:paypal_account_id, payment.payer_id)
          # Add to the lookup map for future payments in this run
          paypal_user_map[payment.payer_id] = user.id
        end

        case match_type
        when :payer_id then paypal_by_payer_id += 1
        when :email then paypal_by_email += 1
        when :name then paypal_by_name += 1
        end
      else
        paypal_no_match += 1
      end
    end

    paypal_updated = paypal_by_payer_id + paypal_by_email + paypal_by_name

    # Count already linked
    paypal_already_linked = PaypalPayment.where.not(user_id: nil).count - paypal_updated

    puts "  Already linked: #{paypal_already_linked}"
    puts "  Newly linked by payer ID: #{paypal_by_payer_id}"
    puts "  Newly linked by email: #{paypal_by_email}"
    puts "  Newly linked by name: #{paypal_by_name}"
    puts "  Total newly linked: #{paypal_updated}"
    puts "  No matching user: #{paypal_no_match}"

    # Process Recharge payments
    puts "\n#{'-' * 60}"
    puts 'Processing Recharge payments...'

    recharge_by_customer_id = 0
    recharge_by_email = 0
    recharge_by_name = 0
    recharge_no_match = 0

    RechargePayment.where(user_id: nil).find_each do |payment|
      user = nil
      match_type = nil

      # 1. Try to match by customer_id
      if payment.customer_id.present?
        user_id = recharge_user_map[payment.customer_id]
        if user_id
          user = User.find_by(id: user_id)
          match_type = :customer_id
        end
      end

      # 2. Try to match by email
      if user.nil? && payment.customer_email.present?
        normalized_email = payment.customer_email.strip.downcase
        user = email_to_user[normalized_email]
        match_type = :email if user
      end

      # 3. Try to match by name
      if user.nil? && payment.customer_name.present?
        normalized_name = payment.customer_name.strip.downcase
        user = name_to_user[normalized_name]
        match_type = :name if user
      end

      if user
        # Link the payment to the user
        payment.update_column(:user_id, user.id)

        # If matched by email or name, also set the recharge_customer_id on the user
        if match_type != :customer_id && payment.customer_id.present? && user.recharge_customer_id.blank?
          user.update_column(:recharge_customer_id, payment.customer_id.to_s)
          # Add to the lookup map for future payments in this run
          recharge_user_map[payment.customer_id] = user.id
        end

        case match_type
        when :customer_id then recharge_by_customer_id += 1
        when :email then recharge_by_email += 1
        when :name then recharge_by_name += 1
        end
      else
        recharge_no_match += 1
      end
    end

    recharge_updated = recharge_by_customer_id + recharge_by_email + recharge_by_name

    # Count already linked
    recharge_already_linked = RechargePayment.where.not(user_id: nil).count - recharge_updated

    puts "  Already linked: #{recharge_already_linked}"
    puts "  Newly linked by customer ID: #{recharge_by_customer_id}"
    puts "  Newly linked by email: #{recharge_by_email}"
    puts "  Newly linked by name: #{recharge_by_name}"
    puts "  Total newly linked: #{recharge_updated}"
    puts "  No matching user: #{recharge_no_match}"

    # Update user statuses (payment type, membership status, dues status)
    puts "\n#{'-' * 60}"
    puts 'Updating user statuses...'
    status_updates = update_user_statuses

    # Set membership dates
    puts "\n#{'-' * 60}"
    puts 'Setting membership dates...'
    update_membership_dates

    # Link membership plans based on PayPal transaction subjects
    puts "\n#{'-' * 60}"
    puts 'Linking membership plans from PayPal transaction subjects...'
    plans_linked = link_membership_plans_from_paypal

    # Summary
    puts "\n#{'=' * 60}"
    puts 'SUMMARY'
    puts '=' * 60
    puts "PayPal payments linked: #{paypal_updated}"
    puts "Recharge payments linked: #{recharge_updated}"
    puts "Total payments linked: #{paypal_updated + recharge_updated}"
    puts "User statuses updated: #{status_updates}"
    puts "Membership plans linked: #{plans_linked[:primary]} primary, #{plans_linked[:supplementary]} supplementary"
    puts "\nDone!"
  end

  # Helper method to update user payment type, membership status, and dues status
  def update_user_statuses
    users_updated = 0

    # Find all users with linked payments
    user_ids_with_payments = (
      PaypalPayment.where.not(user_id: nil).select(:user_id).distinct.pluck(:user_id) +
      RechargePayment.where.not(user_id: nil).select(:user_id).distinct.pluck(:user_id)
    ).uniq

    User.where(id: user_ids_with_payments).find_each do |user|
      next if user.sponsored?

      updates = {}

      # Find most recent payment from each source
      latest_paypal = user.paypal_payments.maximum(:transaction_time)
      latest_recharge = user.recharge_payments.maximum(:processed_at)

      # Determine payment type based on which has more recent payment
      if latest_paypal.present? && latest_recharge.present?
        updates[:payment_type] = latest_paypal > latest_recharge ? 'paypal' : 'recharge'
      elsif latest_paypal.present?
        updates[:payment_type] = 'paypal'
      elsif latest_recharge.present?
        updates[:payment_type] = 'recharge'
      end

      # Find the absolute most recent payment date
      most_recent = [latest_paypal, latest_recharge].compact.max

      payment_attrs = {}
      payment_attrs[:payment_type] = updates[:payment_type] if updates.key?(:payment_type)
      payment_attrs[:last_payment_date] = most_recent.to_date if most_recent.present?

      if payment_attrs[:last_payment_date].present?
        if Membership::ActiveStatus.record_linked_payment!(user, **payment_attrs)
          users_updated += 1
          puts "  #{user.display_name}: #{payment_attrs.map { |k, v| "#{k}=#{v}" }.join(', ')}"
        end
      elsif payment_attrs[:payment_type].present? && payment_attrs[:payment_type] != user.payment_type
        user.update!(payment_type: payment_attrs[:payment_type])
        users_updated += 1
        puts "  #{user.display_name}: payment_type=#{payment_attrs[:payment_type]}"
      end
    end

    puts "  Users updated: #{users_updated}"
    users_updated
  end

  # Helper method to update membership dates for all users with payments
  def update_membership_dates
    users_updated = 0
    users_skipped = 0

    User.find_each do |user|
      # Collect all payment dates for this user
      paypal_dates = user.paypal_payments
                         .where.not(transaction_time: nil)
                         .order(:transaction_time)
                         .pluck(:transaction_time)
      recharge_dates = user.recharge_payments.where.not(processed_at: nil).order(:processed_at).pluck(:processed_at)

      # Skip if no payments
      if paypal_dates.empty? && recharge_dates.empty?
        users_skipped += 1
        next
      end

      updates = {}

      # Find earliest payment of each type
      earliest_paypal = paypal_dates.first
      earliest_recharge = recharge_dates.first

      # Determine membership_start_date:
      # Set to 1 month after the first payment of whichever type came first
      earliest_payment = if earliest_paypal.present? && earliest_recharge.present?
                           [earliest_paypal, earliest_recharge].min
                         else
                           earliest_paypal || earliest_recharge
                         end

      if earliest_payment.present?
        start_date = (earliest_payment + 1.month).to_date
        updates[:membership_start_date] = start_date if user.membership_start_date.nil?
      end

      # Find most recent payment of each type
      latest_paypal = paypal_dates.last
      latest_recharge = recharge_dates.last

      # Determine membership_ended_date from the member's own payment window rather than a
      # hardcoded day count.
      latest_payment = if latest_paypal.present? && latest_recharge.present?
                         [latest_paypal, latest_recharge].max
                       else
                         latest_paypal || latest_recharge
                       end

      if latest_payment.present?
        window = user.payment_currency_window
        if window && latest_payment.to_date < window.ago.to_date
          updates[:membership_ended_date] = (latest_payment + 1.month).to_date
        elsif user.membership_ended_date.present?
          updates[:membership_ended_date] = nil
        end

        plan = user.membership_plan
        if plan.present? && !user.membership_state.in?(%w[guest_member sponsored_member])
          at = User.dues_due_at_from_payment_cycle(latest_payment.to_date, plan)
          updates[:dues_due_at] = at if at
        end
      end

      if updates.any?
        Membership::ActiveStatus.assign_and_save!(user, updates)
        users_updated += 1
        if updates[:membership_start_date] || updates[:membership_ended_date]
          start_str = if updates[:membership_start_date]
                        updates[:membership_start_date].to_s
                      else
                        user.membership_start_date&.to_s || 'nil'
                      end
          end_str = if updates[:membership_ended_date]
                      updates[:membership_ended_date].to_s
                    else
                      (updates.key?(:membership_ended_date) ? 'cleared' : (user.membership_ended_date&.to_s || 'nil'))
                    end
          puts "  #{user.display_name}: start=#{start_str}, ended=#{end_str}"
        end
      else
        users_skipped += 1
      end
    end

    puts "  Users updated: #{users_updated}"
    puts "  Users skipped (no changes): #{users_skipped}"
  end

  # Helper method to link membership plans based on PayPal transaction subjects
  def link_membership_plans_from_paypal
    primary_linked = 0
    supplementary_linked = 0

    # Get all plans that have transaction subjects defined
    plans_with_subjects = MembershipPlan.with_transaction_subject.to_a

    if plans_with_subjects.empty?
      puts '  No membership plans with PayPal transaction subjects configured'
      return { primary: 0, supplementary: 0 }
    end

    puts "  Found #{plans_with_subjects.size} plans with transaction subjects:"
    plans_with_subjects.each do |plan|
      puts "    - #{plan.name} (#{plan.plan_type}): '#{plan.paypal_transaction_subject}'"
    end

    # Process each user with PayPal payments
    User.joins(:paypal_payments).distinct.find_each do |user|
      # Find all unique plans that match this user's PayPal payments
      matched_plans = Set.new

      user.paypal_payments.each do |payment|
        next if payment.raw_attributes.blank?

        raw_json = payment.raw_attributes.to_s

        plans_with_subjects.each do |plan|
          matched_plans << plan if raw_json.include?(plan.paypal_transaction_subject)
        end
      end

      next if matched_plans.empty?

      # Process matched plans
      matched_plans.each do |plan|
        if plan.primary?
          # Assign primary plan if user doesn't have one
          if user.membership_plan_id.nil?
            user.update_column(:membership_plan_id, plan.id)
            primary_linked += 1
            puts "  #{user.display_name}: Primary plan set to '#{plan.name}'"
          elsif user.membership_plan_id != plan.id
            # User already has a different primary plan - skip but note
            puts "  #{user.display_name}: Already has primary plan " \
                 "'#{user.membership_plan.name}', skipping '#{plan.name}'"
          end
        elsif !user.has_plan?(plan) && user.add_supplementary_plan(plan)
          # Add supplementary plan if not already assigned
          supplementary_linked += 1
          puts "  #{user.display_name}: Added supplementary plan '#{plan.name}'"
        end
      end
    end

    puts "  Primary plans linked: #{primary_linked}"
    puts "  Supplementary plans linked: #{supplementary_linked}"

    { primary: primary_linked, supplementary: supplementary_linked }
  end

  desc 'Show payment linking statistics without making changes'
  task link_stats: :environment do
    puts '=' * 60
    puts 'Payment Linking Statistics'
    puts '=' * 60

    # PayPal stats
    puts "\nPayPal Payments:"
    matched_paypal = PaypalPayment.matching_plan
    total_paypal = matched_paypal.count
    linked_paypal = matched_paypal.where.not(user_id: nil).count
    unlinked_with_payer_id = matched_paypal.where(user_id: nil).where.not(payer_id: [nil, '']).count
    unlinked_no_payer_id = matched_paypal.where(user_id: nil, payer_id: [nil, '']).count
    dont_link_paypal = matched_paypal.where(dont_link: true).count
    unmatched_plan_paypal = PaypalPayment.not_matching_plan.count

    # Count how many unlinked could be matched
    paypal_user_map = User.where.not(paypal_account_id: [nil, ''])
                          .pluck(:paypal_account_id, :id)
                          .to_h
    matchable_paypal = matched_paypal.where(user_id: nil)
                                     .where.not(payer_id: [nil, ''])
                                     .where(payer_id: paypal_user_map.keys)
                                     .count

    puts "  Total (matching plans): #{total_paypal}"
    puts "  Linked: #{linked_paypal}"
    puts "  Don't Link: #{dont_link_paypal}"
    puts "  Unlinked (with payer ID): #{unlinked_with_payer_id}"
    puts "  Unlinked (no payer ID): #{unlinked_no_payer_id}"
    puts "  Could be linked now: #{matchable_paypal}"
    puts "  Not matching any plan: #{unmatched_plan_paypal}"

    # Recharge stats
    puts "\nRecharge Payments:"
    total_recharge = RechargePayment.count
    linked_recharge = RechargePayment.where.not(user_id: nil).count
    unlinked_with_customer_id = RechargePayment.where(user_id: nil).where.not(customer_id: [nil, '']).count
    unlinked_no_customer_id = RechargePayment.where(user_id: nil, customer_id: [nil, '']).count
    dont_link_recharge = RechargePayment.where(dont_link: true).count

    # Count how many unlinked could be matched
    recharge_user_map = User.where.not(recharge_customer_id: [nil, ''])
                            .pluck(:recharge_customer_id, :id)
                            .to_h
    matchable_recharge = RechargePayment.where(user_id: nil)
                                        .where.not(customer_id: [nil, ''])
                                        .where(customer_id: recharge_user_map.keys)
                                        .count

    puts "  Total: #{total_recharge}"
    puts "  Linked: #{linked_recharge}"
    puts "  Don't Link: #{dont_link_recharge}"
    puts "  Unlinked (with customer ID): #{unlinked_with_customer_id}"
    puts "  Unlinked (no customer ID): #{unlinked_no_customer_id}"
    puts "  Could be linked now: #{matchable_recharge}"

    # Membership plan stats
    puts "\nMembership Plans (with transaction subjects):"
    plans_with_subjects = MembershipPlan.with_transaction_subject.to_a
    puts "  Configured plans: #{plans_with_subjects.size}"
    plans_with_subjects.each do |plan|
      puts "    - #{plan.name} (#{plan.plan_type}): '#{plan.paypal_transaction_subject}'"
    end

    if plans_with_subjects.any?
      # Count users without primary plans who could get one
      users_without_primary = User.where(membership_plan_id: nil).count
      puts "  Users without primary plan: #{users_without_primary}"
    end

    puts "\n#{'=' * 60}"
    puts "Run 'rails payments:link' to link #{matchable_paypal + matchable_recharge} payments"
  end

  desc 'Link orphaned payments (where one payment is linked but others with same ID are not)'
  task link_orphans: :environment do
    puts '=' * 60
    puts 'Linking orphaned payments'
    puts '=' * 60

    # Find PayPal payer_ids that have both linked and unlinked payments
    puts "\nScanning PayPal payments..."

    paypal_orphans_linked = 0

    # Get all payer_ids that have at least one linked payment (only plan-matching payments)
    linked_payer_ids = PaypalPayment.matching_plan.where.not(user_id: nil)
                                    .where.not(payer_id: [nil, ''])
                                    .distinct
                                    .pluck(:payer_id)

    linked_payer_ids.each do |payer_id|
      # Find the user this payer_id is linked to
      linked_payment = PaypalPayment.matching_plan.where(payer_id: payer_id).where.not(user_id: nil).first
      next unless linked_payment

      # Find and link any unlinked plan-matching payments with the same payer_id
      count = PaypalPayment.matching_plan.where(payer_id: payer_id, user_id: nil)
                           .update_all(user_id: linked_payment.user_id)

      next unless count.positive?

      puts "  Linked #{count} PayPal payment#{if count != 1
                                                's'
                                              end} for payer_id #{payer_id} to user #{linked_payment.user.display_name}"
      paypal_orphans_linked += count
    end

    puts "  Total PayPal orphans linked: #{paypal_orphans_linked}"

    # Find Recharge customer_ids that have both linked and unlinked payments
    puts "\nScanning Recharge payments..."

    recharge_orphans_linked = 0

    # Get all customer_ids that have at least one linked payment
    linked_customer_ids = RechargePayment.where.not(user_id: nil)
                                         .where.not(customer_id: [nil, ''])
                                         .distinct
                                         .pluck(:customer_id)

    linked_customer_ids.each do |customer_id|
      # Find the user this customer_id is linked to
      linked_payment = RechargePayment.where(customer_id: customer_id).where.not(user_id: nil).first
      next unless linked_payment

      # Find and link any unlinked payments with the same customer_id
      count = RechargePayment.where(customer_id: customer_id, user_id: nil)
                             .update_all(user_id: linked_payment.user_id)

      next unless count.positive?

      suffix = count == 1 ? '' : 's'
      user_name = linked_payment.user.display_name
      puts "  Linked #{count} Recharge payment#{suffix} " \
           "for customer_id #{customer_id} to user #{user_name}"
      recharge_orphans_linked += count
    end

    puts "  Total Recharge orphans linked: #{recharge_orphans_linked}"

    # Summary
    puts "\n#{'=' * 60}"
    puts 'SUMMARY'
    puts '=' * 60
    puts "PayPal orphans linked: #{paypal_orphans_linked}"
    puts "Recharge orphans linked: #{recharge_orphans_linked}"
    puts "Total orphans linked: #{paypal_orphans_linked + recharge_orphans_linked}"
    puts "\nDone!"
  end

  desc 'Download all available PayPal payments, store new ones, and process them (match plans, link users)'
  task paypal_full_sync: :environment do
    unless PaypalConfig.enabled?
      puts 'PayPal integration is not configured. Set PAYPAL_CLIENT_ID and PAYPAL_CLIENT_SECRET.'
      next
    end

    # PayPal Transaction Search API allows up to 3 years of history
    lookback_days = ENV.fetch('PAYPAL_FULL_SYNC_DAYS', '1095').to_i # 3 years default
    start_time = Time.current - lookback_days.days

    puts '=' * 60
    puts 'PayPal Full Sync'
    puts '=' * 60
    puts "Fetching all PayPal transactions from #{start_time.strftime('%Y-%m-%d')} to now (#{lookback_days} days)"
    puts 'Set PAYPAL_FULL_SYNC_DAYS to change the lookback period (max ~1095 for 3 years)'
    puts ''

    # Get allowed transaction subjects for plan matching
    plan_subjects = MembershipPlan.with_transaction_subject
                                  .pluck(:paypal_transaction_subject)
                                  .compact
    subjects_display = plan_subjects.any? ? plan_subjects.join(', ') : 'NONE (all payments will be unmatched!)'
    puts "Payment plan subjects configured: #{subjects_display}"
    puts ''

    # Fetch transactions from PayPal API
    puts 'Downloading transactions from PayPal API...'
    client = Paypal::Client.new
    begin
      payments = client.transactions(start_time: start_time)
    rescue Faraday::ForbiddenError => e
      puts 'ERROR: PayPal API returned 403 Forbidden.'
      puts "Your PayPal app may not have 'Transaction Search' / 'Reporting API' enabled."
      next
    rescue StandardError => e
      puts "ERROR: #{e.class}: #{e.message}"
      next
    end

    puts "Downloaded #{payments.count} transactions from PayPal"
    puts ''

    # Build user lookup tables
    puts 'Building user lookup tables...'
    payer_id_to_user = User.where.not(paypal_account_id: [nil, ''])
                           .index_by(&:paypal_account_id)

    email_to_user = {}
    name_to_user = {}
    User.find_each do |user|
      email_to_user[user.email.to_s.strip.downcase] = user if user.email.present?
      if user.extra_emails.present?
        user.extra_emails.each do |extra|
          email_to_user[extra.to_s.strip.downcase] = user
        end
      end
      name_to_user[user.full_name.to_s.strip.downcase] = user if user.full_name.present?
    end
    puts "  #{payer_id_to_user.size} users with PayPal account IDs"
    puts "  #{email_to_user.size} email addresses indexed"
    puts "  #{name_to_user.size} names indexed"
    puts ''

    # Process payments
    now = Time.current
    new_count = 0
    updated_count = 0
    matched_plan_count = 0
    unmatched_plan_count = 0
    linked_user_count = 0
    error_count = 0

    puts "Processing #{payments.count} transactions..."

    PaypalPayment.transaction do
      payments.each do |attrs|
        # Determine if this payment matches a plan
        matches_plan = false
        if attrs[:raw_attributes].present? && plan_subjects.any?
          raw_json = attrs[:raw_attributes].to_json
          matches_plan = plan_subjects.any?(raw_json.method(:include?))
        end

        if matches_plan
          matched_plan_count += 1
        else
          unmatched_plan_count += 1
        end

        record = PaypalPayment.find_or_initialize_by(paypal_id: attrs[:paypal_id])
        is_new = record.new_record?

        record.assign_attributes(
          status: attrs[:status],
          amount: attrs[:amount],
          currency: attrs[:currency],
          transaction_time: attrs[:transaction_time],
          transaction_type: attrs[:transaction_type],
          payer_email: attrs[:payer_email],
          payer_name: attrs[:payer_name],
          payer_id: attrs[:payer_id],
          raw_attributes: attrs[:raw_attributes],
          last_synced_at: now,
          matches_plan: matches_plan
        )

        # Try to link to a user (for all payments, not just plan-matching ones)
        if record.user_id.blank?
          payer_id = attrs[:payer_id].to_s.strip
          payer_email = attrs[:payer_email].to_s.strip.downcase
          payer_name = attrs[:payer_name].to_s.strip.downcase

          user = payer_id_to_user[payer_id] if payer_id.present?
          user ||= email_to_user[payer_email] if payer_email.present?
          user ||= name_to_user[payer_name] if payer_name.present?

          if user
            record.user = user
            linked_user_count += 1 if is_new || record.user_id_changed?
          end
        end

        record.save!

        if is_new
          new_count += 1
        else
          updated_count += 1
        end
      rescue ActiveRecord::RecordInvalid => e
        error_count += 1
        puts "  ERROR saving payment #{attrs[:paypal_id]}: #{e.message}"
      end
    end

    # Summary
    puts ''
    puts '=' * 60
    puts 'SUMMARY'
    puts '=' * 60
    puts "Total transactions from API:  #{payments.count}"
    puts "New payments stored:          #{new_count}"
    puts "Existing payments updated:    #{updated_count}"
    puts "Errors:                       #{error_count}"
    puts ''
    puts 'Plan matching:'
    puts "  Matched a plan:             #{matched_plan_count}"
    puts "  Did not match a plan:       #{unmatched_plan_count}"
    puts ''
    puts 'User linking:'
    puts "  Newly linked to users:      #{linked_user_count}"
    puts ''
    puts 'Database totals:'
    puts "  Total PayPal payments:      #{PaypalPayment.count}"
    puts "  Matching plans:             #{PaypalPayment.matching_plan.count}"
    puts "  Not matching plans:         #{PaypalPayment.not_matching_plan.count}"
    puts "  Linked to users:            #{PaypalPayment.where.not(user_id: nil).count}"
    puts "  Unlinked:                   #{PaypalPayment.where(user_id: nil).count}"
    puts ''
    puts 'Done!'
  end
end
