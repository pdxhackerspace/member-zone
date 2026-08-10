namespace :users do
  desc 'Move users with a recent linked payment to current_member'
  task update_recent_payments: :environment do
    # The window comes from the member's plan rather than a hardcoded 32 days; User
    # resolves a payment that no longer covers them back to overdue on save.
    updated_count = 0

    User.where.not(last_payment_date: nil).find_each do |user|
      next if user.membership_state.in?(User::PAYMENT_IMMUNE_STATES) || user.current_member?
      next if user.dues_paid_through_at.present? && user.dues_paid_through_at <= Time.current

      user.record_payment!
      updated_count += 1
      puts "Updated #{user.display_name}: #{user.membership_state}"
    end

    puts "\nTotal users updated: #{updated_count}"
  end
end
