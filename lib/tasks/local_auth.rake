namespace :local_auth do
  desc 'Create or repair the local sign-in account from LOCAL_AUTH_EMAIL / LOCAL_AUTH_PASSWORD'
  task provision: :environment do
    settings = LocalAuthConfig.settings

    unless LocalAuthConfig.enabled?
      puts 'LOCAL_AUTH_ENABLED is false; local sign-in would be refused even with an account.'
    end

    if settings.default_email.blank? || settings.default_password.blank?
      puts 'ERROR: LOCAL_AUTH_EMAIL and LOCAL_AUTH_PASSWORD are both required'
      exit 1
    end

    account = LocalAccount.provision!(
      email: settings.default_email,
      password: settings.default_password,
      full_name: settings.default_full_name
    )

    puts "Local sign-in ready: #{account.email} (id #{account.id})"
    puts LocalAuth::UnreadableAccounts.message if LocalAuth::UnreadableAccounts.any?
  end

  desc 'Report local accounts whose address no longer decrypts (PRUNE=1 to delete them)'
  task prune_unreadable: :environment do
    found = LocalAuth::UnreadableAccounts.ids

    if found.empty?
      puts 'Every local account decrypts with the configured key. Nothing to do.'
      next
    end

    # Deleting is opt-in twice over: a wrong or missing DATABASE_FIELD_ENCRYPTION_KEY makes
    # every account look unreadable, and that must not be the moment emergency access is
    # thrown away.
    unless ENV['PRUNE'] == '1'
      puts "Would delete #{found.size} unreadable local account(s): id #{found.join(', ')}"
      puts 'Re-run with PRUNE=1 to delete them. Check DATABASE_FIELD_ENCRYPTION_KEY first.'
      next
    end

    puts "Deleted #{LocalAuth::UnreadableAccounts.prune!.size} unreadable local account(s)."
  end
end
