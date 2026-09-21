module ReminderSettingsHelper
  # Where a row on a due list is in its reminder sequence.
  #
  # The answer has to be the one Schedule gives the job, restart rule included: a parking
  # notice with a new expiration date, or a member on a fresh overdue spell, is at reminder
  # one however many the previous sequence sent. Reading the raw count would show "3 of 3"
  # beside somebody who is about to be mailed again.
  #
  # Reads the delivery index the controller loaded, so a page of fifty rows costs one query
  # rather than fifty.
  def reminder_progress_for(subject, reminder = @reminder_setting)
    return Reminders::Schedule::NOTHING_SENT if subject.blank? || reminder.blank?

    reminder.schedule.progress_from(reminder_delivery_for(subject),
                                    anchor: reminder_anchor_for(subject, reminder))
  end

  def reminder_delivery_for(subject)
    return nil if subject.blank?

    (@reminder_deliveries || {})[subject.id]
  end

  def reminder_last_sent_at(subject, reminder = @reminder_setting)
    reminder_progress_for(subject, reminder).last_sent_at
  end

  def reminder_sent_count(subject, reminder = @reminder_setting)
    reminder_progress_for(subject, reminder).sent_count
  end

  # "2 of 3" when the reminder has a maximum, plain "2" when it repeats indefinitely.
  def reminder_sent_count_display(subject, reminder = @reminder_setting)
    sent = reminder_sent_count(subject, reminder)
    return sent.to_s if reminder.unlimited_reminders?

    "#{sent} of #{reminder.max_reminders}"
  end

  private

  # Each eligibility service owns what its subjects count from, so ask the one that owns this
  # reminder rather than teaching the view about anchors. Prefers the index the controller
  # loaded: lapsed access has to query for an anchor, and a page is fifty rows.
  def reminder_anchor_for(subject, reminder)
    return @reminder_anchors[subject.id] if @reminder_anchors&.key?(subject.id)

    Reminders::Registry.eligibility_for(reminder.key)&.anchor(subject)
  end
end
