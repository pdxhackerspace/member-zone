namespace :credentials do
  desc 'Ask a credential provider\'s program what it issues and cache the answer: credentials:describe[PROVIDER]'
  task :describe, [:provider] => :environment do |_task, args|
    provider = CredentialsTaskHelper.find_provider(args[:provider])
    outcome = Credentials::Describe.call(provider)
    if outcome.ok?
      puts "#{provider.name}: #{provider.reload.schema_fields.pluck('key').join(', ')} " \
           "(actions: #{provider.schema_actions.join(', ')})"
    else
      puts "#{provider.name}: could not read the schema: #{outcome.error}"
    end
  end

  desc 'Run a credential provider\'s health check: credentials:health[PROVIDER]'
  task :health, [:provider] => :environment do |_task, args|
    provider = CredentialsTaskHelper.find_provider(args[:provider])
    status = Credentials::HealthCheck.call(provider)
    puts "#{provider.name}: #{status}#{": #{provider.reload.health_message}" if provider.health_message.present?}"
  end

  desc 'Warn about credentials expiring within a week and mark expired ones (what the daily job does)'
  task expire: :environment do
    CredentialsTaskHelper.print_expiry(Credentials::Expirer.call, dry_run: false)
  end

  desc 'Show what credentials:expire would do, without doing it (dry run)'
  task expire_preview: :environment do
    CredentialsTaskHelper.print_expiry(Credentials::Expirer.call(dry_run: true), dry_run: true)
  end

  desc 'Sync members whose credentials no longer match their standing, retry failed revokes (what the daily job does)'
  task reconcile: :environment do
    CredentialsTaskHelper.print_reconcile(Credentials::Reconciler.call, dry_run: false)
  end

  desc 'Show what credentials:reconcile would do, without doing it (dry run)'
  task reconcile_preview: :environment do
    CredentialsTaskHelper.print_reconcile(Credentials::Reconciler.call(dry_run: true), dry_run: true)
  end

  desc 'Revoke every live credential of one member: credentials:revoke_member[USER_ID]'
  task :revoke_member, [:user_id] => :environment do |_task, args|
    user = CredentialsTaskHelper.find_user(args[:user_id])
    report = Credentials::RevokeAll.call(user.credentials, reason: 'revoked_by_admin')
    puts "#{user.display_name}: revoked #{report.revoked.size}, failed #{report.failed.size}"
  end

  desc 'Show what credentials:revoke_member would revoke, without doing it (dry run)'
  task :revoke_member_preview, [:user_id] => :environment do |_task, args|
    user = CredentialsTaskHelper.find_user(args[:user_id])
    report = Credentials::RevokeAll.call(user.credentials, dry_run: true)
    puts "[DRY RUN] #{user.display_name}: would revoke #{report.candidates.size}"
    report.candidates.each { |credential| puts "  #{CredentialsTaskHelper.describe(credential)}" }
  end
end

# Helpers for the tasks above, kept out of the namespace so they can be unit tested.
module CredentialsTaskHelper
  module_function

  def find_provider(identifier)
    abort 'Usage: rails credentials:describe[PROVIDER_NAME_OR_ID]' if identifier.blank?

    CredentialProvider.find_by(id: identifier.to_s[/\A\d+\z/]) || CredentialProvider.find_by!(name: identifier)
  end

  def find_user(identifier)
    abort 'Usage: rails credentials:revoke_member[USER_ID]' if identifier.blank?

    User.find(identifier)
  end

  def describe(credential)
    "##{credential.id} #{credential.credential_provider.name} (#{credential.label.presence || 'no label'}) " \
      "for #{credential.user.display_name}"
  end

  def print_expiry(report, dry_run:)
    prefix = dry_run ? '[DRY RUN] ' : ''
    puts "#{prefix}#{report.warned.size} to warn, #{report.expired.size} to expire"
    report.warned.each do |credential|
      puts "  warn   #{describe(credential)}, expires #{credential.expires_at.to_date}"
    end
    report.expired.each { |credential| puts "  expire #{describe(credential)}" }
  end

  def print_reconcile(report, dry_run:)
    prefix = dry_run ? '[DRY RUN] ' : ''
    puts "#{prefix}#{report.users.size} members to sync, #{report.retried.size} revokes to retry, " \
         "#{report.stale.size} stale issues"
    report.users.each { |user| puts "  sync  #{user.display_name} (id #{user.id})" }
    report.retried.each { |credential| puts "  retry #{describe(credential)}" }
    report.stale.each { |credential| puts "  stale #{describe(credential)}" }
  end
end
