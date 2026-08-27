module Notifications
  # Single choke point for member notification opt-outs. Returns true when delivery should
  # be suppressed for the given mailer action and recipient.
  class DeliveryGate
    OPT_OUT_REJECTION_DETAILS = 'Auto-rejected: recipient opted out'.freeze

    class << self
      def blocked?(mailer_action:, user: nil, email: nil, channel: 'email')
        category = NotificationCategory.for_mailer_action(mailer_action)
        return false unless category

        return false unless category.reminder_key && NotificationCategory.opt_out_allowed?(category.key)

        if email_based_category?(category)
          address = email.presence || user&.email
          return false if address.blank?

          return true if EmailNotificationOptOut.opted_out?(address, category: category.key, channel: channel)

          resolved_user = user.is_a?(User) ? user : User.lookup_by_email(address)
          NotificationOptOut.opted_out?(resolved_user, category: category.key, channel: channel)
        else
          return false if user.blank?

          NotificationOptOut.opted_out?(user, category: category.key, channel: channel)
        end
      end

      def block_queued_delivery!(queued_mail)
        return false unless blocked?(
          mailer_action: queued_mail.mailer_action,
          user: queued_mail.recipient,
          email: queued_mail.to
        )
        return true if queued_mail.rejected?

        queued_mail.update!(status: 'rejected', reviewed_by: nil, reviewed_at: Time.current)
        MailLogEntry.log!(queued_mail, 'rejected', details: OPT_OUT_REJECTION_DETAILS)
        true
      end

      def opt_out_alert_message(queued_mail)
        category = NotificationCategory.for_mailer_action(queued_mail.mailer_action)
        notification_name = category&.name&.downcase || 'this notification'
        recipient_name = queued_mail.recipient&.display_name || queued_mail.to
        "Message not sent: #{recipient_name} opted out of #{notification_name}."
      end

      def opt_out_rejection?(queued_mail)
        return false unless queued_mail.rejected?

        queued_mail.mail_log_entries.where(event: 'rejected').order(created_at: :desc).pick(:details) ==
          OPT_OUT_REJECTION_DETAILS
      end

      def footer_for(mailer_action:, user: nil, email: nil, verification_token: nil)
        category = NotificationCategory.for_mailer_action(mailer_action)
        return FooterPresenter.none unless category

        preferences_token = notification_preferences_token_for(user)

        FooterPresenter.new(
          category: category,
          user: user.is_a?(User) ? user : nil,
          email: email,
          verification_token: verification_token,
          notification_preferences_token: preferences_token
        )
      end

      private

      def notification_preferences_token_for(user)
        return unless user.is_a?(User)

        user.generate_token_for(:notification_preferences)
      end

      def email_based_category?(category)
        category.key == 'application_link'
      end
    end
  end
end
