module Slack
  class MemberProfileSync
    def self.apply(user:, slack_user:, logger: Rails.logger)
      new(user: user, slack_user: slack_user, logger: logger).apply
    end

    def initialize(user:, slack_user:, logger: Rails.logger)
      @user = user
      @slack_user = slack_user
      @logger = logger
    end

    def apply
      @user.add_alias!(@slack_user.real_name) if @slack_user.real_name.present?

      sync_email
      sync_profile_fields
      sync_profile_links
    end

    private

    def sync_email
      email = @slack_user.email
      return if email.blank?

      if @user.email.blank?
        @user.update!(email: email)
      elsif @user.email.downcase != email.downcase
        extra_emails = @user.extra_emails || []
        return if extra_emails.map(&:downcase).include?(email.downcase)

        @user.update!(extra_emails: extra_emails + [email])
      end
    end

    def sync_profile_fields
      updates = {}
      updates[:slack_id] = @slack_user.slack_id if @user.slack_id.blank?
      updates[:slack_handle] = @slack_user.username if @user.slack_handle.blank?
      updates[:pronouns] = @slack_user.pronouns if @slack_user.pronouns.present? && @user.pronouns.blank?

      profile = @slack_user.raw_attributes&.dig('profile') || {}
      image_192_url = profile['image_192']
      updates[:avatar] = image_192_url if image_192_url.present? && replace_avatar?(profile)
      updates[:bio] = @slack_user.title if @slack_user.title.present? && @user.bio.blank?

      @user.update!(updates) if updates.any?
    end

    # A blank avatar only takes a photo the member actually uploaded. Slack's default
    # image_192 is a Gravatar URL, and storing it makes the next real photo look custom.
    def replace_avatar?(profile)
      return slack_avatar? if @user.avatar.present?

      profile['image_original'].present?
    end

    def slack_avatar?
      avatar = @user.avatar.to_s
      return true if avatar == @slack_user.raw_attributes&.dig('openid_claims', 'picture')

      host = URI.parse(avatar).host.to_s.downcase
      slack_host?(host) || slack_default_gravatar?(avatar, host)
    rescue URI::InvalidURIError
      false
    end

    def slack_host?(host)
      host == 'slack-edge.com' || host.end_with?('.slack-edge.com') ||
        host == 'slack.com' || host.end_with?('.slack.com')
    end

    # No uploaded photo: image_192 is Gravatar, and its fallback image is hosted on Slack.
    def slack_default_gravatar?(avatar, host)
      return false unless host == 'gravatar.com' || host.end_with?('.gravatar.com')

      decoded = URI.decode_www_form_component(avatar).downcase
      decoded.include?('slack-edge.com') || decoded.include?('.slack.com')
    rescue ArgumentError
      false
    end

    def sync_profile_links
      profile = @slack_user.raw_attributes&.dig('profile') || {}
      return if @user.user_links.any?

      links_to_create = profile_links_from(profile)
      links_to_create.each_with_index do |link_attrs, index|
        @user.user_links.create!(
          title: link_attrs[:title],
          url: link_attrs[:url],
          position: index
        )
      rescue ActiveRecord::RecordInvalid => e
        @logger.warn("Failed to create user link for #{@user.id}: #{e.message}")
      end
    end

    def profile_links_from(profile)
      links = []
      fields = profile['fields'] || {}
      fields.each_value do |field_data|
        next unless field_data.is_a?(Hash)

        value = field_data['value'].to_s.strip
        label = field_data['label'].to_s.strip
        next unless value.match?(%r{^https?://})

        links << { title: label.presence || title_from_url(value), url: value }
      end
      links
    end

    def title_from_url(url)
      case url.downcase
      when /github\.com/ then 'GitHub'
      when /linkedin\.com/ then 'LinkedIn'
      when /twitter\.com|x\.com/ then 'Twitter/X'
      when /instagram\.com/ then 'Instagram'
      when /facebook\.com/ then 'Facebook'
      when /youtube\.com/ then 'YouTube'
      when /mastodon|hachyderm|fosstodon/ then 'Mastodon'
      when /gitlab\.com/ then 'GitLab'
      else 'Website'
      end
    end
  end
end
