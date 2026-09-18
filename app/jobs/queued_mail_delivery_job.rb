# Hands an approved message to the mail server once, now.
#
# Retrying is deliberately not this job's business. +QueuedMail#deliver_now!+ has already recorded
# the failure on the row by the time the exception gets here, and +QueuedMailRetrySweepJob+ owns
# the backoff, the attempt budget, and the question of whether there is a mail server to try at
# all. A +retry_on+ here would resend the message on a second, invisible schedule: it ignores the
# backoff, spends attempts the budget never accounted for, and keeps trying while email is
# disabled. +claim_for_delivery!+ does not cover that — it stops two callers delivering at the
# same moment, not one caller delivering twice in a row.
class QueuedMailDeliveryJob < ApplicationJob
  queue_as :default

  def perform(queued_mail_id)
    QueuedMail.find(queued_mail_id).deliver_now!
  rescue ActiveRecord::RecordNotFound
    Rails.logger.info("[QueuedMailDelivery] queued_mail_id=#{queued_mail_id} no longer exists")
  rescue StandardError => e
    Rails.logger.warn(
      "[QueuedMailDelivery] queued_mail_id=#{queued_mail_id} failed, left to the retry sweep — " \
      "#{e.class}: #{e.message}"
    )
  end
end
