# The Reminders page's view of the API token expiry reminder, kept out of
# ReminderSettingsController so the controller stays inside its size limit.
module ApiTokenExpiryReminderData
  extend ActiveSupport::Concern

  private

  def api_token_expiry_counts
    { due: Reminders::ApiTokenExpiryEligibility.count_due,
      context: "#{Reminders::ApiTokenExpiryEligibility.total_expiring} tokens within the reminder window",
      note: 'Sent to the token\'s contact, or to the token managers when the contact cannot be reached, so ' \
            'members cannot opt out of it.' }
  end

  def load_api_token_expiry_show_data
    @pagy, @due_api_tokens = pagy(Reminders::ApiTokenExpiryEligibility.due, limit: self.class::PER_PAGE)
    @api_token_expiry_due_count = @pagy.count
    @api_token_expiry_window_count = Reminders::ApiTokenExpiryEligibility.total_expiring
    load_delivery_index(@due_api_tokens)
  end
end
