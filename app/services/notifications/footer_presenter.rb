module Notifications
  # Renders opt-out or mandatory footer copy for member-facing emails.
  class FooterPresenter
    include Rails.application.routes.url_helpers

    def self.none
      new(category: nil)
    end

    def initialize(category:, user: nil, email: nil, verification_token: nil, notification_preferences_token: nil)
      @category = category
      @user = user
      @email = email
      @verification_token = verification_token
      @notification_preferences_token = notification_preferences_token
    end

    delegate :present?, to: :@category, allow_nil: true

    def mandatory?
      present? && !NotificationCategory.opt_out_allowed?(@category.key)
    end

    def opt_out_allowed?
      present? && NotificationCategory.opt_out_allowed?(@category.key)
    end

    def html
      return '' if @category.blank?

      if opt_out_allowed?
        opt_out_html
      elsif mandatory?
        mandatory_html
      else
        ''
      end
    end

    def text
      return '' if @category.blank?

      if opt_out_allowed?
        opt_out_text
      elsif mandatory?
        mandatory_text
      else
        ''
      end
    end

    private

    def opt_out_html
      url = preferences_url
      return '' if url.blank?

      <<~HTML
        <p class="notification-footer" style="margin-top: 24px; font-size: 14px; color: #666666;">
          <a href="#{ERB::Util.html_escape(url)}">Manage #{ERB::Util.html_escape(@category.name.downcase)}</a>
          or turn them off in your notification settings.
        </p>
      HTML
    end

    def mandatory_html
      url = manage_notifications_url
      manage_link = if url.present?
                      " <a href=\"#{ERB::Util.html_escape(url)}\">Manage your other notifications</a>."
                    else
                      ''
                    end

      <<~HTML
        <p class="notification-footer" style="margin-top: 24px; font-size: 14px; color: #666666;">
          This is a required notice and cannot be turned off.#{manage_link}
        </p>
      HTML
    end

    def opt_out_text
      url = preferences_url
      return '' if url.blank?

      "Manage #{@category.name.downcase} or turn them off: #{url}\n"
    end

    def mandatory_text
      url = manage_notifications_url
      line = 'This is a required notice and cannot be turned off.'
      url.present? ? "#{line} Manage your other notifications: #{url}\n" : "#{line}\n"
    end

    def preferences_url
      if @user.present? && @notification_preferences_token.present?
        token_notification_preferences_url(
          token: @notification_preferences_token,
          highlight: @category.key,
          **default_url_options
        )
      elsif @verification_token.present?
        applicant_notification_opt_out_url(@verification_token, category: @category.key, **default_url_options)
      end
    rescue ArgumentError, ActionController::UrlGenerationError
      base = ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')
      if @user.present? && @notification_preferences_token.present?
        "#{base}/notifications/#{@notification_preferences_token}?highlight=#{@category.key}"
      elsif @verification_token.present?
        "#{base}/apply/notifications/#{@verification_token}/opt-out?category=#{@category.key}"
      end
    end

    def manage_notifications_url
      return unless @user.present? && @notification_preferences_token.present?

      token_notification_preferences_url(token: @notification_preferences_token, **default_url_options)
    rescue ArgumentError, ActionController::UrlGenerationError
      base = ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')
      "#{base}/notifications/#{@notification_preferences_token}"
    end

    def default_url_options
      Rails.application.config.action_mailer.default_url_options || {}
    end
  end
end
