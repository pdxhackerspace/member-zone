# Shared by application groups and custom core groups: both are ApplicationGroup rows
# pushed to Authentik the same way.
module AuthentikGroupSyncing
  extend ActiveSupport::Concern

  private

  def sync_group_to_authentik(group)
    return { status: 'skipped', reason: 'api_not_configured' } unless authentik_api_configured?

    Authentik::GroupSync.new(group).sync!
  rescue StandardError => e
    Rails.logger.error("[AuthentikGroupSyncing] Authentik sync failed: #{e.message}")
    { status: 'error', error: e.message }
  end

  def sync_group_members(group)
    return { status: 'skipped', reason: 'no_authentik_group_id' } if group.authentik_group_id.blank?
    return { status: 'skipped', reason: 'api_not_configured' } unless authentik_api_configured?

    Authentik::GroupSync.new(group).sync_members!
  rescue StandardError => e
    Rails.logger.error("[AuthentikGroupSyncing] Authentik member sync failed: #{e.message}")
    { status: 'error', error: e.message }
  end

  def delete_authentik_group(group)
    return if group.authentik_group_id.blank?

    Authentik::GroupSync.new(group).delete!
  rescue StandardError => e
    Rails.logger.error("[AuthentikGroupSyncing] Failed to delete group from Authentik: #{e.message}")
  end

  def authentik_api_configured?
    AuthentikConfig.settings.api_token.present? && AuthentikConfig.settings.api_base_url.present?
  end

  def build_sync_notice(base_message, sync_result)
    return base_message if sync_result.nil?

    case sync_result[:status]
    when 'created'
      "#{base_message} Group created in Authentik."
    when 'exists'
      "#{base_message} Linked to existing Authentik group."
    when 'updated', 'synced'
      synced_member_notice(base_message, sync_result)
    when 'error'
      "#{base_message} Warning: Authentik sync failed — #{sync_failure_detail(sync_result[:error])}"
    else
      base_message
    end
  end

  # Authentik (and the proxy in front of it) sometimes returns an HTML error page. The notice
  # only needs the reason, not the document.
  def sync_failure_detail(error)
    error.to_s.sub(/:\s*<.*/m, '').squish.truncate(160)
  end

  def synced_member_notice(base_message, sync_result)
    members_info = sync_result[:members] || sync_result
    added = members_info[:added].to_i
    removed = members_info[:removed].to_i
    return "#{base_message} Synced to Authentik." unless added.positive? || removed.positive?

    "#{base_message} Authentik sync: +#{added} / -#{removed} members."
  end
end
