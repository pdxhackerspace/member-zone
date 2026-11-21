# The Reminders page's view of the training-resource digest, kept out of
# ReminderSettingsController so the controller stays inside its size limit.
module TrainingResourceUpdatesReminderData
  extend ActiveSupport::Concern

  private

  def training_resource_update_counts
    summary = TrainingResources::UpdateDigest.summary
    { due: summary.due_recipient_count, context: summary.context, note: summary.note }
  end

  def load_training_resource_updates_show_data
    @training_resource_summary = TrainingResources::UpdateDigest.summary
    @training_resource_due_count = @training_resource_summary.due_recipient_count
    @pagy, @pending_resource_changes = pagy(pending_resource_changes, limit: self.class::PER_PAGE)
  end

  def pending_resource_changes
    TrainingResourceChange.pending.includes(:training_topic, :actor).order(occurred_at: :desc)
  end
end
