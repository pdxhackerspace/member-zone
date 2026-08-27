module Notifications
  # Single choke point for member notification opt-outs. Returns true when delivery should
  # be suppressed for the given mailer action and recipient.
  class DeliveryGate
    class << self
      def blocked?(mailer_action:, user: nil, email: nil, channel: 'email')
        category = NotificationCategory.for_mailer_action(mailer_action)
        return false unless category

        return false unless category.reminder_key && NotificationCategory.opt_out_allowed?(category.key)

        if email_based_category?(category)
          address = email.presence || user&.email
          return false if address.blank?

          EmailNotificationOptOut.opted_out?(address, category: category.key, channel: channel)
        else
          return false if user.blank?

          NotificationOptOut.opted_out?(user, category: category.key, channel: channel)
        end
      end

      def footer_for(mailer_action:, user: nil, email: nil, verification_token: nil)
        category = NotificationCategory.for_mailer_action(mailer_action)
        return FooterPresenter.none unless category

        preferences_token = user&.generate_token_for(:notification_preferences) if user.present?

        FooterPresenter.new(
          category: category,
          user: user,
          email: email,
          verification_token: verification_token,
          notification_preferences_token: preferences_token
        )
      end

      private

      def email_based_category?(category)
        category.key == 'application_link'
      end
    end
  end
end
