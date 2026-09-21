module Authentik
  class FullSyncToAuthentikJob < ApplicationJob
    queue_as :default

    def perform
      unless MemberSource.enabled?('member_zone')
        Rails.logger.info('Member Zone source is disabled — skipping sync to Authentik.')
        return
      end

      client = Authentik::Client.new
      results = { users_created: 0, users_synced: 0, users_skipped: 0, users_errored: 0, groups_synced: 0,
                  groups_errored: 0, critical_authentik_errors: [] }

      # 1. Create Authentik accounts for members without an authentik_id
      Rails.logger.info('[Authentik::FullSyncToAuthentik] Creating missing Authentik users...')
      User.where(authentik_id: [nil, '']).find_each do |user|
        create_user_in_authentik(user, client, results)
      end

      # 2. Sync dirty members with an authentik_id to Authentik
      dirty_users = User.authentik_dirty.where.not(authentik_id: [nil, ''])
      Rails.logger.info("[Authentik::FullSyncToAuthentik] Syncing #{dirty_users.count} dirty user(s)...")
      dirty_users.find_each do |user|
        sync_user_to_authentik(user, client, results)
      end

      supplemental_user_ids = Authentik::UserAttributes.supplemental_sync_user_ids
      supplemental_users = User.where(id: supplemental_user_ids)
                               .where.not(authentik_id: [nil, ''])
                               .where(authentik_dirty: false)
      Rails.logger.info(
        '[Authentik::FullSyncToAuthentik] Syncing supplemental attributes ' \
        "for #{supplemental_users.count} user(s)..."
      )
      supplemental_users.find_each do |user|
        sync_supplemental_attributes_to_authentik(user, client, results)
      end

      # 2a. Ensure core groups (active, admins, unbanned, all, training) exist
      Rails.logger.info('[Authentik::FullSyncToAuthentik] Provisioning core groups...')
      provisioner = Authentik::CoreGroupProvisioner.new
      provision_results = provisioner.provision!
      Rails.logger.info(
        '[Authentik::FullSyncToAuthentik] Core groups: ' \
        "created=#{provision_results[:created].count}, " \
        "existing=#{provision_results[:existing].count}"
      )

      # 2b. Sync all ApplicationGroup groups
      Rails.logger.info('[Authentik::FullSyncToAuthentik] Syncing application groups...')
      ApplicationGroup.find_each do |app_group|
        sync_application_group(app_group, client, results)
      end

      # 3. Sync the active members group (the configured Authentik group)
      sync_active_members_group(client, results)

      Rails.logger.info("[Authentik::FullSyncToAuthentik] Complete: #{results.inspect}")

      if results[:critical_authentik_errors].any?
        MemberSource.for('authentik').record_failed_sync!(results[:critical_authentik_errors].join('; '))
      elsif MemberSource.enabled?('authentik')
        MemberSource.for('authentik').record_sync!
      end

      results
    rescue StandardError => e
      if MemberSource.enabled?('member_zone')
        MemberSource.for('authentik').record_failed_sync!("#{e.class}: #{e.message}")
      end
      raise
    end

    private

    def create_user_in_authentik(user, client, results)
      # Need at least a username or email to create in Authentik
      username = user.username.presence || user.email.presence
      if username.blank?
        results[:users_skipped] += 1
        Rails.logger.warn(
          "[Authentik::FullSyncToAuthentik] Skipping user #{user.id} " \
          "(#{user.display_name}): no username or email"
        )
        return
      end

      name = user.full_name.presence || user.display_name

      # Check if user already exists in Authentik by username
      existing = client.find_user_by_username(username)
      if existing
        # Link the existing Authentik user and push current attributes (including Slack).
        authentik_id = existing['pk'].to_s
        user.update_columns(authentik_id: authentik_id, last_synced_at: Time.current, authentik_dirty: false)
        client.update_user(authentik_id, attributes: Authentik::UserAttributes.for(user))
        results[:users_synced] += 1
        Rails.logger.info(
          '[Authentik::FullSyncToAuthentik] Linked existing Authentik user ' \
          "#{authentik_id} to user #{user.id} (#{user.display_name})"
        )
        return
      end

      # Create the user in Authentik
      result = client.create_user(
        username: username,
        name: name,
        email: user.email,
        is_active: Authentik::ActiveStatus.for(user),
        attributes: Authentik::UserAttributes.for(user)
      )

      authentik_id = result['pk'].to_s
      user.update_columns(authentik_id: authentik_id, last_synced_at: Time.current, authentik_dirty: false)
      results[:users_created] += 1

      Rails.logger.info(
        '[Authentik::FullSyncToAuthentik] Created Authentik user ' \
        "#{authentik_id} for user #{user.id} (#{user.display_name})"
      )
    rescue StandardError => e
      # The job carries on to the next member, so nothing raises and Sidekiq never sees this.
      # The tally in results says how many failed but never which, and the run is reported as a
      # success either way — so without this a member who never got an Authentik account stays
      # that way until somebody notices they cannot sign in.
      results[:users_errored] += 1
      Rails.logger.error(
        '[Authentik::FullSyncToAuthentik] Failed to create Authentik user ' \
        "for #{user.id} (#{user.display_name}): #{e.message}"
      )
      ErrorReporting.report(e, context: { job: 'full_sync_to_authentik', stage: 'create_user', user_id: user.id })
    end

    def sync_user_to_authentik(user, client, results)
      attrs = {}

      # Core fields
      attrs[:email] = user.email if user.email.present?
      attrs[:name] = user.full_name if user.full_name.present?
      attrs[:username] = user.username if user.username.present?
      attrs[:is_active] = Authentik::ActiveStatus.for(user)

      attrs[:attributes] = Authentik::UserAttributes.for(user)

      client.update_user(user.authentik_id, **attrs)
      user.update_columns(last_synced_at: Time.current, authentik_dirty: false)
      results[:users_synced] += 1

      Rails.logger.info("[Authentik::FullSyncToAuthentik] Synced user #{user.id} (#{user.display_name})")
    rescue StandardError => e
      results[:users_errored] += 1
      Rails.logger.error("[Authentik::FullSyncToAuthentik] Failed to sync user #{user.id}: #{e.message}")
      ErrorReporting.report(e, context: { job: 'full_sync_to_authentik', stage: 'sync_user', user_id: user.id })
    end

    def sync_supplemental_attributes_to_authentik(user, client, results)
      client.update_user(user.authentik_id, attributes: Authentik::UserAttributes.for(user))
      user.update_columns(last_synced_at: Time.current)
      results[:users_synced] += 1

      Rails.logger.info(
        '[Authentik::FullSyncToAuthentik] Synced supplemental attributes ' \
        "for user #{user.id} (#{user.display_name})"
      )
    rescue StandardError => e
      results[:users_errored] += 1
      Rails.logger.error(
        '[Authentik::FullSyncToAuthentik] Failed to sync supplemental attributes ' \
        "for user #{user.id}: #{e.message}"
      )
      ErrorReporting.report(e, context: { job: 'full_sync_to_authentik', stage: 'supplemental_attributes',
                                          user_id: user.id })
    end

    def sync_application_group(app_group, client, results)
      group_sync = Authentik::GroupSync.new(app_group, client: client)
      result = group_sync.sync!

      if result[:status] == 'error'
        results[:groups_errored] += 1
        Rails.logger.error(
          '[Authentik::FullSyncToAuthentik] Failed to sync group ' \
          "'#{app_group.name}': #{result[:error]}"
        )
      else
        results[:groups_synced] += 1
        Rails.logger.info("[Authentik::FullSyncToAuthentik] Synced group '#{app_group.name}'")
      end
    rescue StandardError => e
      results[:groups_errored] += 1
      Rails.logger.error("[Authentik::FullSyncToAuthentik] Failed to sync group '#{app_group.name}': #{e.message}")
      ErrorReporting.report(e, context: { job: 'full_sync_to_authentik', stage: 'sync_application_group',
                                          application_group_id: app_group.id })
    end

    def sync_active_members_group(client, results)
      group_id = AuthentikConfig.settings.group_id
      return if group_id.blank?

      Rails.logger.info("[Authentik::FullSyncToAuthentik] Syncing active members group (#{group_id})...")

      # Get all active users with authentik_id
      active_user_pks = User.active.where.not(authentik_id: [nil, '']).pluck(:authentik_id).map(&:to_i)

      client.set_group_users(group_id, active_user_pks)
      Rails.logger.info(
        '[Authentik::FullSyncToAuthentik] Active members group synced ' \
        "with #{active_user_pks.count} members"
      )
    rescue StandardError => e
      Rails.logger.error("[Authentik::FullSyncToAuthentik] Failed to sync active members group: #{e.message}")
      results[:critical_authentik_errors] << "Active members group: #{e.message}"
    end
  end
end
