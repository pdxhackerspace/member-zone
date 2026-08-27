module Notifications
  # Shared SQL helpers for reminder eligibility scopes.
  module EligibilityOptOuts
    module_function

    def user_scope_excluding_opt_outs(relation, reminder_key, channel: 'email')
      category = category_for_reminder(reminder_key)
      return relation unless category && NotificationCategory.opt_out_allowed?(category)

      relation.where.not(id: NotificationOptOut.opted_out_user_ids(category: category, channel: channel))
    end

    def verification_scope_excluding_opt_outs(relation, reminder_key, channel: 'email')
      category = category_for_reminder(reminder_key)
      return relation unless category && NotificationCategory.opt_out_allowed?(category)

      digests = EmailNotificationOptOut.opted_out_digests(category: category, channel: channel)
      relation.where.not(email_lookup_digest: digests)
    end

    def category_for_reminder(reminder_key)
      NotificationCategory.reminder_backed.find { |entry| entry.reminder_key == reminder_key.to_s }&.key
    end
  end
end
