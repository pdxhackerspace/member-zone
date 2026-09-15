# Re-attempts approved messages that never went out.
#
# Messages land here when email was disabled or the mail server was unreachable at the moment they
# were raised, or when a delivery job exhausted its own retries. Nothing about them needs review, so
# this keeps trying on the schedule in +QueuedMailRetries+ until they land. While email is disabled
# the sweep does nothing at all rather than burning each message's attempt budget on a server that
# is not there.
class QueuedMailRetrySweepJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 100

  def perform
    blocked_reason = MailDeliveryReadiness.unavailable_reason
    if blocked_reason
      Rails.logger.info("[QueuedMailRetrySweep] skipped — #{blocked_reason}")
      return
    end

    due = QueuedMail.awaiting_retry.limit(BATCH_SIZE).select(&:retry_due?)
    return if due.empty?

    Rails.logger.info("[QueuedMailRetrySweep] retrying #{due.size} #{'message'.pluralize(due.size)}")
    due.each { |queued_mail| deliver(queued_mail) }
  end

  private

  # +QueuedMail#deliver_now!+ records the failure and re-raises; swallow it here so one unreachable
  # recipient does not stop the rest of the sweep.
  def deliver(queued_mail)
    queued_mail.deliver_now!
  rescue StandardError => e
    Rails.logger.warn(
      "[QueuedMailRetrySweep] queued_mail_id=#{queued_mail.id} attempt #{queued_mail.send_attempts} " \
      "failed — #{e.class}: #{e.message}"
    )
  end
end
