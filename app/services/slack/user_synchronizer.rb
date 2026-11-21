module Slack
  class UserSynchronizer
    include UserNameMatcher

    SyncResult = Struct.new(:synced_count, :linked_count, :skipped_count, :updated_count, :created_count,
                            :create_failed_count)

    def initialize(client: Client.new, logger: Rails.logger)
      @client = client
      @logger = logger
    end

    def call(update_members: false)
      members = @client.list_users
      synced_ids = []

      SlackUser.transaction do
        members.each do |attrs|
          synced_ids << attrs[:slack_id]
          upsert_slack_record(attrs)
        end
        deactivate_missing_members(synced_ids)
      end

      link_stats = link_matching_members
      update_stats = update_members ? sync_member_accounts : empty_member_stats

      MemberSource.for('slack').record_sync!

      SyncResult.new(
        synced_ids.count,
        link_stats[:linked],
        link_stats[:skipped],
        update_stats[:updated],
        update_stats[:created],
        update_stats[:create_failed]
      )
    end

    private

    def upsert_slack_record(attrs)
      record = SlackUser.find_or_initialize_by(slack_id: attrs[:slack_id])
      claims = record.raw_attributes&.dig('openid_claims')
      record.assign_attributes(attrs)
      record.raw_attributes = (record.raw_attributes || {}).merge('openid_claims' => claims) if claims.present?
      # A savepoint, because the whole run shares one transaction: another session claiming
      # this address first trips the unique index on the email digest, and Postgres would
      # otherwise leave the transaction aborted and take the rest of the sync down with it.
      SlackUser.transaction(requires_new: true) { record.save! }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      @logger.error("Failed to sync Slack user #{attrs[:slack_id]}: #{e.message}")
    end

    def link_matching_members
      linked = 0
      skipped = 0

      linkable_slack_users.find_each do |slack_user|
        matches = matching_users_for(slack_user)
        if matches.one?
          slack_user.update!(user_id: matches.first.id)
          linked += 1
        else
          skipped += 1
        end
      end

      { linked: linked, skipped: skipped }
    end

    def sync_member_accounts
      updated = update_linked_member_profiles
      create_stats = create_missing_members
      { updated: updated, created: create_stats[:created], create_failed: create_stats[:create_failed] }
    end

    def update_linked_member_profiles
      updated = 0

      SlackUser.human.not_deactivated.where.not(user_id: nil).includes(:user).find_each do |slack_user|
        user = slack_user.user
        next if user.blank?

        MemberProfileSync.apply(user: user, slack_user: slack_user, logger: @logger)
        updated += 1
      end

      updated
    end

    def create_missing_members
      created = 0
      create_failed = 0

      linkable_slack_users.find_each do |slack_user|
        next unless matching_users_for(slack_user).none?

        result = MemberCreator.call(slack_user: slack_user)
        if result.success?
          created += 1
        else
          create_failed += 1
          @logger.warn("Failed to create member from Slack user #{slack_user.slack_id}: #{result.message}")
        end
      end

      { created: created, create_failed: create_failed }
    end

    def matching_users_for(slack_user)
      matches = []

      if slack_user.email.present?
        normalized_email = slack_user.email.to_s.strip.downcase
        matches += User.by_any_email(normalized_email)
      end

      matches += User.by_name_or_alias(slack_user.real_name) if slack_user.real_name.present?

      matches.uniq
    end

    def linkable_slack_users
      SlackUser.human.not_deactivated.where(user_id: nil, dont_link: false)
    end

    def empty_member_stats
      { updated: 0, created: 0, create_failed: 0 }
    end

    def deactivate_missing_members(synced_ids)
      return if synced_ids.empty?

      SlackUser.where.not(slack_id: synced_ids).where(deleted: false).update_all(deleted: true,
                                                                                 updated_at: Time.current)
    end
  end
end
