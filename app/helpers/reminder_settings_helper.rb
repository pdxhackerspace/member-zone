module ReminderSettingsHelper
  # The two due-list columns answer different questions and so read the delivery row
  # differently, which is worth stating because they look like they should agree.
  #
  # "Last reminder" asks when we last emailed this subject. That is a fact about what left the
  # building, and it stays true across a restart. Lapsed access makes the distinction obvious:
  # every new batch of visits is a new anchor — that is how a member becomes due again — so
  # filtering the timestamp through the restart rule would report "Never" for somebody who was
  # emailed yesterday.
  #
  # "Sent" asks how far through the *current* sequence they are, which is the number the job
  # acts on, so it does apply the restart rule. A parking notice with a new expiration date is
  # at reminder one however many the finished sequence sent.
  #
  # Both read the delivery index the controller loaded, so a page of fifty rows costs one
  # query rather than fifty.
  def reminder_delivery_for(subject)
    return nil if subject.blank?

    (@reminder_deliveries || {})[subject.id]
  end

  def reminder_last_sent_at(subject)
    reminder_delivery_for(subject)&.last_sent_at
  end

  def reminder_progress_for(subject, reminder = @reminder_setting)
    return Reminders::Schedule::NOTHING_SENT if subject.blank? || reminder.blank?

    reminder.schedule.progress_from(reminder_delivery_for(subject),
                                    anchor: reminder_anchor_for(subject, reminder))
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
