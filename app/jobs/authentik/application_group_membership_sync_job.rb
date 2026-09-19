module Authentik
  class ApplicationGroupMembershipSyncJob < ApplicationJob
    queue_as :default

    def perform(member_sources)
      return unless api_configured?

      unless MemberSource.enabled?('member_zone')
        Rails.logger.info('Member Zone source is disabled — skipping application group membership sync.')
        return
      end

      groups = groups_for_member_sources(member_sources)
      return if groups.empty?

      Rails.logger.info(
        "[ApplicationGroupMembershipSyncJob] Syncing #{groups.count} groups " \
        "for sources: #{member_sources.join(', ')}"
      )

      groups.each do |group|
        sync = Authentik::GroupSync.new(group)
        result = sync.sync_members!
        Rails.logger.info("[ApplicationGroupMembershipSyncJob] Synced #{group.name}: #{result[:status]}")
      rescue StandardError => e
        # Swallowed so one bad group does not strand the rest, which also means the job reports
        # success and Sidekiq never hears about it. A group left unsynced is a member holding
        # access they should not have, or missing access they should.
        Rails.logger.error("[ApplicationGroupMembershipSyncJob] Failed to sync #{group.name}: #{e.message}")
        ErrorReporting.report(e, context: { job: 'application_group_membership_sync',
                                            application_group_id: group.id })
      end
    end

    private

    def api_configured?
      AuthentikConfig.settings.api_token.present? && AuthentikConfig.settings.api_base_url.present?
    end

    def groups_for_member_sources(member_sources)
      source_groups = ApplicationGroup.with_member_sources(Array(member_sources).compact).to_a
      groups_with_sync_dependents(source_groups).select { |group| group.authentik_group_id.present? }
    end

    def groups_with_sync_dependents(source_groups)
      groups_by_id = source_groups.index_by(&:id)
      frontier_ids = groups_by_id.keys

      until frontier_ids.empty?
        dependent_groups = ApplicationGroup.where(member_source: 'sync_group', sync_with_group_id: frontier_ids).to_a
        new_groups = dependent_groups.reject { |group| groups_by_id.key?(group.id) }

        new_groups.each { |group| groups_by_id[group.id] = group }
        frontier_ids = new_groups.map(&:id)
      end

      groups_by_id.values
    end
  end
end
