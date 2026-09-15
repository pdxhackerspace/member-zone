# Retry policy for approved messages that have not gone out yet.
#
# A message waits here because delivery failed (server unreachable, refusing, or email disabled at
# the moment it was raised) or because its delivery job was lost. None of it needs a second review,
# so +QueuedMailRetrySweepJob+ retries on a widening interval until the message lands or the
# attempt budget runs out, at which point it sits in the queue for an admin to look at.
module QueuedMailRetries
  extend ActiveSupport::Concern

  MAX_SEND_ATTEMPTS = 12
  RETRY_BACKOFF = [1.minute, 5.minutes, 15.minutes, 1.hour, 3.hours, 6.hours].freeze

  # A message with no recorded failure normally has a delivery job in flight — it was just approved,
  # or an admin just asked for a retry. Wait for that job to run out of its own retries before
  # taking it over, measured from the last write rather than from when it was queued.
  UNATTEMPTED_GRACE = 15.minutes

  included do
    scope :awaiting_retry, -> { unsent.order(:created_at) }
  end

  # Cleared to send but not out yet, so nobody needs to review or approve it — it is waiting on the
  # mail server, not on a human.
  def queued_for_retry?
    approved? && sent_at.nil?
  end

  def retry_due?(now: Time.current)
    return false unless queued_for_retry?
    return false if retries_exhausted?
    return updated_at + UNATTEMPTED_GRACE <= now if last_error_at.blank?

    last_error_at + retry_interval <= now
  end

  def retries_exhausted?
    send_attempts >= MAX_SEND_ATTEMPTS
  end

  def next_retry_at
    return nil if sent? || retries_exhausted? || last_error_at.blank?

    last_error_at + retry_interval
  end

  private

  def retry_interval
    RETRY_BACKOFF[[send_attempts - 1, 0].max] || RETRY_BACKOFF.last
  end
end
