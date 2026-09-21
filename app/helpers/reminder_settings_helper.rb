module ReminderSettingsHelper
  # Where a row on a due list is in its reminder sequence. Reads the index the controller
  # loaded, so a page of fifty rows costs one query rather than fifty.
  def reminder_delivery_for(subject)
    return nil if subject.blank?

    (@reminder_deliveries || {})[subject.id]
  end

  def reminder_last_sent_at(subject)
    reminder_delivery_for(subject)&.last_sent_at
  end

  def reminder_sent_count(subject)
    reminder_delivery_for(subject)&.sent_count.to_i
  end

  # "2 of 3" when the reminder has a maximum, plain "2" when it repeats indefinitely.
  def reminder_sent_count_display(subject, reminder)
    sent = reminder_sent_count(subject)
    return sent.to_s if reminder.unlimited_reminders?

    "#{sent} of #{reminder.max_reminders}"
  end
end
