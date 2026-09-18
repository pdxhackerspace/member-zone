# Handing an approved message to the mail server, and what happens when that does not work.
#
# The one rule everything here is built around: a message may be delivered at most once. Only the
# handoff itself counts as a delivery failure, because a failure recorded after the mail server
# has the message hands a delivered message back to +QueuedMailRetrySweepJob+ to be sent again.
# The retry policy itself lives in +QueuedMailRetries+.
module QueuedMailDelivery
  extend ActiveSupport::Concern

  class_methods do
    # Stores an already-rendered direct delivery that could not be sent, as an approved message
    # carrying the failure, so the retry and the admin's view of it are the same ones that
    # template-backed mail gets.
    #
    # Without this a failed +deliver_later+ leaves nothing but a log line: the rendered message is
    # gone, there is nothing for an admin to look at or retry, and the only thing still trying is
    # the Sidekiq retry on the mailer job — which knows nothing about mail, so it resends on its
    # own schedule for days. Returns nil when there is no body worth storing, leaving the caller to
    # raise as before.
    #
    # It does not go back for review: nobody approved it in the first place.
    # rubocop:disable-next Metrics/ParameterLists -- mirrors mail metadata fields
    def capture_failed_delivery(to:, subject:, body_html:, mailer_action:, error:, body_text: nil, recipient: nil)
      return nil if to.blank? || subject.blank? || body_html.blank?

      error_message = "#{error.class}: #{error.message}"
      record = create!(
        **queued_mail_attrs(to, mailer_action.to_s.humanize, recipient, mailer_action.to_s, {}),
        subject: subject.truncate(500),
        body_html: body_html,
        body_text: body_text || '',
        status: 'approved',
        last_error: error_message,
        last_error_at: Time.current
      )
      MailLogEntry.log!(record, 'created',
                        details: "Queued #{mailer_action.to_s.humanize} to #{to} for retry — #{error_message}")
      record
    end
  end

  # Safe to call from anywhere that thinks the message is due: an already-sent message is left
  # alone, and the claim keeps a retry sweep and an in-flight delivery job from both sending it.
  def deliver_now!
    return if sent? || !approved?
    return if MailRecipientGuard.block_delivery_to!(self)
    return if Notifications::DeliveryGate.block_queued_delivery!(self)

    if (reason = undeliverable_reason)
      Rails.logger.info("[QueuedMail] not attempting ##{id}: #{reason}")
      return
    end
    return unless claim_for_delivery!

    record_delivery_bookkeeping!(hand_to_mail_server!)
  end

  # Why this attempt should not be made at all, or nil. Asked here rather than only in the retry
  # sweep so that no caller can spend an attempt the retry policy never authorised: an exhausted
  # message waits for an admin to press Retry, and one with no mail server to hand to waits for one.
  def undeliverable_reason
    return "automatic retries stopped after #{send_attempts} attempts" if retries_exhausted?

    MailDeliveryReadiness.unavailable_reason
  end

  # An admin asking for a retry also restores the automatic attempt budget, so a message that had
  # given up starts being swept again if this attempt fails too.
  def retry_delivery!
    update!(last_error: nil, last_error_at: nil, send_attempts: 0)
    QueuedMailDeliveryJob.perform_later(id)
  end

  def record_delivery_failure!(error)
    MailerDeliveryMonitor.record_failure!(error, source: "QueuedMail##{id}")
    error_message = "#{error.class}: #{error.message}"
    update!(last_error: error_message, last_error_at: Time.current)
    MailLogEntry.log_once!(self, 'send_failed', details: error_message)
  end

  private

  # The +sent_at+ stamp is the only record that the message left, so the stamp is deliberately the
  # only thing standing between the handoff and returning: a failure to write it means the message
  # went out and the row does not know it, which is bad, but recording it as a send failure would
  # be worse — the sweep would deliver it a second time within the minute.
  def hand_to_mail_server!
    begin
      QueuedMailMailer.deliver_queued(self).deliver_now
    rescue StandardError => e
      record_delivery_failure!(e)
      raise
    end

    sent_time = Time.current
    update!(sent_at: sent_time, last_error: nil, last_error_at: nil)
    sent_time
  end

  # Runs once the message is out and the row says so, so nothing here may be mistaken for a
  # delivery failure. The log entry is best-effort. The reminder stamps are not: they are what stop
  # a reminder job from deciding the member is still due and queueing the same mail again on its
  # next tick, so a failure there is raised for the job log rather than swallowed.
  def record_delivery_bookkeeping!(sent_time)
    begin
      MailLogEntry.log_queued_delivery!(self)
    rescue StandardError => e
      Rails.logger.error("[QueuedMail] mail log entry failed for ##{id} — #{e.class}: #{e.message}")
    end

    record_reminder_deliveries!(sent_time)
  end
end
