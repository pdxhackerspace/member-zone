# frozen_string_literal: true

module Slack
  # Links a Slack workspace user (from OIDC +sub+) to a Member Zone +User+.
  class AccountLinker
    Result = Struct.new(:status, :message) do
      def success?
        status == :success
      end

      def failure?
        status == :failure
      end
    end

    TEAM_CLAIM = 'https://slack.com/team_id'

    def self.call(user:, id_token_payload:)
      new(user: user, id_token_payload: id_token_payload).call
    end

    def initialize(user:, id_token_payload:)
      @user = user
      @payload = id_token_payload.stringify_keys
    end

    def call
      team_check = verify_team
      return team_check if team_check

      slack_user_id = @payload['sub'].presence || @payload['https://slack.com/user_id'].presence
      return Result.new(:failure, 'Slack did not return a user id.') if slack_user_id.blank?

      slack_user = resolve_slack_user(slack_user_id)
      return Result.new(:failure, missing_profile_message) if slack_user.nil?

      conflict = verify_no_conflicts(slack_user)
      return conflict if conflict

      sync_photo(slack_user)
      return Result.new(:success, 'Your Slack account is already linked.') if slack_user.user_id == @user.id

      slack_user.update!(user_id: @user.id)
      Result.new(:success, 'Your Slack account has been linked.')
    end

    private

    def sync_photo(slack_user)
      picture = @payload['picture'].to_s.strip.presence
      return if picture.blank?

      previous_picture = slack_user.raw_attributes&.dig('openid_claims', 'picture')
      SlackUser.transaction do
        @user.update!(avatar: picture) if @user.avatar.blank? || @user.avatar == previous_picture
        slack_user.update!(raw_attributes: (slack_user.raw_attributes || {}).merge('openid_claims' => @payload))
      end
    end

    def verify_team
      team = @payload[TEAM_CLAIM]
      expected = SlackOidcConfig.settings.team_id.to_s
      return nil if team.present? && team == expected

      Result.new(
        :failure,
        'That Slack sign-in is not from the expected workspace. Use the CTRLH Slack workspace.'
      )
    end

    def resolve_slack_user(slack_user_id)
      slack_user = SlackUser.find_by(slack_id: slack_user_id)
      slack_user ||= upsert_slack_user_from_api(slack_user_id)
      slack_user ||= upsert_slack_user_from_claims(slack_user_id)
      slack_user
    end

    def missing_profile_message
      'Could not load your Slack profile. Ask an admin to run a Slack user sync, then try again.'
    end

    def verify_no_conflicts(slack_user)
      if slack_user.user_id.present? && slack_user.user_id != @user.id
        return Result.new(
          :failure,
          'That Slack account is already linked to another member profile. Ask an admin if this is wrong.'
        )
      end

      other = @user.slack_user
      if other.present? && other.id != slack_user.id
        return Result.new(
          :failure,
          'Your profile is already linked to a different Slack account. Ask an admin to update the link.'
        )
      end

      nil
    end

    def upsert_slack_user_from_api(slack_user_id)
      return nil unless SlackConfig.configured?

      attrs = Client.new.user_info(slack_user_id)
      return nil if attrs.blank? || attrs[:is_bot]

      record = SlackUser.find_or_initialize_by(slack_id: attrs[:slack_id])
      record.assign_attributes(attrs)
      record.save!
      record
    rescue StandardError => e
      Rails.logger.warn("Slack::AccountLinker users.info failed for #{slack_user_id}: #{e.class} #{e.message}")
      nil
    end

    def upsert_slack_user_from_claims(slack_user_id)
      email = @payload['email'].to_s.strip.presence
      email = nil unless email&.match?(URI::MailTo::EMAIL_REGEXP)

      record = SlackUser.find_or_initialize_by(slack_id: slack_user_id)
      record.team_id = @payload[TEAM_CLAIM] if record.team_id.blank?
      record.real_name = @payload['name'].to_s.strip.presence if record.real_name.blank?
      record.email = email if record.email.blank? && email.present?
      record.is_bot = false
      record.deleted = false
      record.raw_attributes = (record.raw_attributes || {}).merge('openid_claims' => @payload)
      record.last_synced_at = Time.current
      record.save!
      record
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("Slack::AccountLinker OIDC upsert failed: #{e.message}")
      nil
    end
  end
end
