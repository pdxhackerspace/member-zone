# Records a reminder against its sequence once the mail has actually gone out.
#
# A reminder can leave by two routes. The daily run enqueues mail and, when that mail goes
# straight to the mail server, records the send itself. Mail held for review leaves days later
# from the mail queue, and that send has to land against the same sequence — otherwise a member
# whose reminder sat in the queue would be due again the next morning.
module QueuedMailReminderDeliveries
  extend ActiveSupport::Concern

  def record_reminder_deliveries!(sent_time)
    reminder_key = ReminderSetting.key_for_mailer_action(mailer_action)
    return if reminder_key.blank?

    subject = Reminders::Registry.subject_for(reminder_key, recipient: recipient, mailer_args: mailer_args)
    return if subject.blank?

    record_reminder_delivery!(reminder_key, subject, sent_time)
  end

  private

  def record_reminder_delivery!(reminder_key, subject, sent_time)
    eligibility = Reminders::Registry.eligibility_for(reminder_key)
    return if eligibility.nil?

    # Lapsed access stamps the visits its email described as well as its own cadence, and only
    # the queued mail knows which visits those were.
    if reminder_key == 'lapsed_access'
      Reminders::NotifyLapsedAccess.record_delivery!(subject, at: sent_time,
                                                              access_log_ids: recorded_access_log_ids)
    else
      eligibility.record_delivery!(subject, at: sent_time)
    end
  rescue StandardError => e
    Rails.logger.error(
      "[QueuedMail] #{reminder_key} reminder stamp failed queued_mail_id=#{id} " \
      "subject=#{subject.class}##{subject.id} #{e.class}: #{e.message}"
    )
    raise
  end

  def recorded_access_log_ids
    mailer_args.is_a?(Hash) ? mailer_args['access_log_ids'] : nil
  end
end
