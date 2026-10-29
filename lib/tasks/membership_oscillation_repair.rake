namespace :membership do
  desc 'Preview repair of members whose state oscillated between a payment sync and a cancellation'
  task repair_oscillation_preview: :environment do
    MembershipOscillationRepair.new(dry_run: true).run
  end

  desc 'Repair members whose state oscillated between a payment sync and a cancellation'
  task repair_oscillation: :environment do
    MembershipOscillationRepair.new(dry_run: false).run
  end
end
