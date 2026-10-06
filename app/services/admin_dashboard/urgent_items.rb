# frozen_string_literal: true

module AdminDashboard
  # Builds the urgent tier shown on the admin dashboard for reuse in notifications.
  class UrgentItems
    include Rails.application.routes.url_helpers

    Item = Data.define(:id, :title, :detail, :url)
    Snapshot = Data.define(
      :items,
      :unread_messages_count,
      :ac_offline_count,
      :ac_sync_failed_count,
      :ac_backup_failed_count,
      :ac_issue_count,
      :payment_processors_sync_unhealthy,
      :authentik_member_source,
      :authentik_api_urgent,
      :authentik_sync_issue,
      :mailer_health,
      :ai_ollama_profiles,
      :ai_ollama_urgent,
      :printers,
      :unhealthy_printers
    )

    def self.call(user: nil)
      snapshot(user: user).items
    end

    def self.snapshot(user: nil)
      new(user: user).snapshot
    end

    def initialize(user: nil)
      @user = user
    end

    def call
      snapshot.items
    end

    def snapshot
      Snapshot.new(
        items,
        unread_messages_count,
        ac_offline_count,
        ac_sync_failed_count,
        ac_backup_failed_count,
        ac_issue_count,
        payment_processors_sync_unhealthy,
        authentik_member_source,
        authentik_api_urgent?,
        authentik_sync_issue,
        mailer_health,
        ai_ollama_profiles,
        ai_ollama_urgent?,
        printers,
        unhealthy_printers
      )
    end

    private

    attr_reader :user

    def items
      [
        unread_messages_item,
        access_controller_item,
        payment_processors_item,
        authentik_item,
        mailer_item,
        ai_ollama_item,
        printers_item,
        credentials_item
      ].compact
    end

    def unread_messages_item
      return nil if unread_messages_count.zero?

      item(
        :unread_messages,
        "#{unread_messages_count} unread #{'message'.pluralize(unread_messages_count)}",
        'Your Member Zone inbox has unread messages.',
        messages_path(folder: :unread)
      )
    end

    def access_controller_item
      return nil if ac_issue_count.zero?

      details = []
      details << "#{ac_offline_count} offline" if ac_offline_count.positive?
      details << "#{ac_sync_failed_count} sync failed" if ac_sync_failed_count.positive?
      details << "#{ac_backup_failed_count} backup failed" if ac_backup_failed_count.positive?

      item(
        :ac_issues,
        "#{ac_issue_count} access controller #{'issue'.pluralize(ac_issue_count)}",
        details.join(', '),
        access_controllers_path
      )
    end

    def payment_processors_item
      return nil if payment_processors_sync_unhealthy.empty?

      details = payment_processors_sync_unhealthy.map do |processor|
        "#{processor.name} (#{processor.status_label})"
      end

      item(
        :payment_processors,
        "#{payment_processors_sync_unhealthy.size} " \
        "payment processor #{'integration'.pluralize(payment_processors_sync_unhealthy.size)} with sync problems",
        details.join(', '),
        payment_processors_path
      )
    end

    def authentik_item
      if authentik_api_urgent?
        return item(
          :authentik,
          'Authentik API integration is not configured',
          'Set AUTHENTIK_TOKEN and a valid API base URL so Member Zone can call Authentik.',
          authentik_webhooks_path
        )
      end

      return nil unless authentik_sync_issue

      item(
        :authentik,
        "Authentik sync is #{authentik_sync_issue.sync_status_label.downcase}",
        authentik_sync_issue.last_error_message.to_s.truncate(200),
        member_source_path(authentik_sync_issue)
      )
    end

    def printers_item
      return nil if unhealthy_printers.empty?

      item(
        :printers,
        "Printers: #{unhealthy_printers.size} unhealthy #{'printer'.pluralize(unhealthy_printers.size)}",
        unhealthy_printers.map { |printer| "#{printer.name}: #{printer.last_health_error}" }.join('; ').truncate(300),
        printers_path
      )
    end

    def credentials_item
      count = CredentialProvider.attention_count
      return nil if count.zero?

      item(
        :credentials,
        "Credentials: #{count} #{'issue'.pluralize(count)} to look at",
        credentials_detail,
        credential_providers_path
      )
    end

    def credentials_detail
      details = []
      unhealthy = CredentialProvider.needing_attention.count
      failed = Credential.revoke_failed.count
      stuck = Credential.stale_pending.count
      details << "#{unhealthy} unhealthy provider(s)" if unhealthy.positive?
      details << "#{failed} revocation(s) failing" if failed.positive?
      details << "#{stuck} issue(s) never finished" if stuck.positive?
      details.join(', ')
    end

    def unread_messages_count
      @unread_messages_count ||= user ? Message.folder(user, :unread).count : 0
    end

    def enabled_access_controllers
      @enabled_access_controllers ||= AccessController.enabled
    end

    def ac_offline_count
      @ac_offline_count ||= enabled_access_controllers.where(ping_status: 'failed').count
    end

    def ac_sync_failed_count
      @ac_sync_failed_count ||= enabled_access_controllers.where(sync_status: 'failed').count
    end

    def ac_backup_failed_count
      @ac_backup_failed_count ||= enabled_access_controllers.where(backup_status: 'failed').count
    end

    def ac_issue_count
      ac_offline_count + ac_sync_failed_count + ac_backup_failed_count
    end

    def payment_processors_sync_unhealthy
      @payment_processors_sync_unhealthy ||=
        PaymentProcessor.enabled
                        .where(sync_status: %w[degraded failing])
                        .order(:name)
                        .to_a
    end

    def authentik_member_source
      return @authentik_member_source if defined?(@authentik_member_source)

      @authentik_member_source = MemberSource.find_by(key: 'authentik')
    end

    def authentik_api_urgent?
      !AuthentikConfig.api_ready? && (AuthentikConfig.enabled_for_login? || authentik_member_source&.enabled?)
    end

    def authentik_sync_issue
      return unless authentik_member_source&.enabled? &&
                    authentik_member_source.sync_status.in?(%w[degraded failing])

      authentik_member_source
    end

    def mailer_health
      @mailer_health ||= MailerHealthCheck.call
    end

    def mailer_item
      return nil if mailer_health.healthy?

      item(
        :mailer_health,
        'Outgoing mail is unhealthy',
        mailer_health.message.to_s.truncate(300),
        mail_log_path
      )
    end

    def ai_ollama_profiles
      @ai_ollama_profiles ||= AiOllamaProfile.ordered.to_a
    end

    def ai_ollama_urgent?
      unhealthy_ai_ollama_profiles.any?
    end

    def unhealthy_ai_ollama_profiles
      @unhealthy_ai_ollama_profiles ||= ai_ollama_profiles.select(&:urgent_health_issue?)
    end

    def printers
      @printers ||= Printer.ordered.to_a
    end

    def unhealthy_printers
      @unhealthy_printers ||= printers.select(&:urgent_health_issue?)
    end

    def ai_ollama_item
      return nil if unhealthy_ai_ollama_profiles.empty?

      item(
        :ai_ollama,
        "AI Services: #{unhealthy_ai_ollama_profiles.size} " \
        "unhealthy #{'service'.pluralize(unhealthy_ai_ollama_profiles.size)}",
        unhealthy_ai_ollama_profiles.map { |profile| "#{profile.name}: #{profile.last_health_error}" }
                                   .join('; ')
                                   .truncate(300),
        ai_ollama_profiles_path
      )
    end

    def item(id, title, detail, path)
      Item.new(id, title, detail, absolute_url(path))
    end

    def absolute_url(path)
      "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')}#{path}"
    end
  end
end
