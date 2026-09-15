# Retry policy for approved messages that have not gone out yet.
#
# A message waits here because delivery failed (server unreachable, refusing, or email disabled at
# the moment it was raised) or because its delivery job was lost. None of it needs a second review,
# so +QueuedMailRetrySweepJob+ retries on a widening interval until the message lands or the
# attempt budget runs out, at which point it sits in the queue for an admin to look at.
#
# Retries deliberately overlap +QueuedMailDeliveryJob+'s own retries rather than trying to guess
# when that job has given up. Overlapping is harmless because +QueuedMail#deliver_now!+ claims the
# row before sending, so only one of them can deliver a given message.
module QueuedMailRetries
  extend ActiveSupport::Concern

  MAX_SEND_ATTEMPTS = 12
  RETRY_BACKOFF = [1.minute, 5.minutes, 15.minutes, 1.hour, 3.hours, 6.hours].freeze

  # A message with no recorded failure normally has a delivery job in flight — it was just approved,
  # or an admin just asked for a retry, or a worker died mid-attempt. Wait before taking it over,
  # measured from the last write rather than from when it was queued.
  UNATTEMPTED_GRACE = 15.minutes

  class_methods do
    # Messages whose next attempt is due, oldest first. The whole test is in SQL so that a batch
    # limit can only ever be filled with messages that are actually due — a backlog of exhausted or
    # still-backing-off messages cannot starve newer mail queued behind it.
    def due_for_retry(now: Time.current)
      backoff_groups(now)
        .reduce(unattempted_retries(now)) { |relation, (attempts, cutoff)| relation.or(attempts_due(attempts, cutoff)) }
        .where(send_attempts: ...MAX_SEND_ATTEMPTS)
        .order(:created_at)
    end

    def retry_interval_for(send_attempts)
      RETRY_BACKOFF[[send_attempts - 1, 0].max] || RETRY_BACKOFF.last
    end

    private

    def unattempted_retries(now)
      unsent.where(last_error_at: nil).where(updated_at: ..(now - UNATTEMPTED_GRACE))
    end

    def attempts_due(send_attempts, cutoff)
      unsent.where(send_attempts: send_attempts, last_error_at: ..cutoff)
    end

    # One entry per distinct backoff step: the attempt counts that share it, paired with the
    # +last_error_at+ at or before which those messages come due.
    def backoff_groups(now)
      (0...MAX_SEND_ATTEMPTS)
        .group_by { |attempts| retry_interval_for(attempts) }
        .map { |interval, attempts| [attempts, now - interval] }
    end
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

  # Takes the message for one delivery attempt, or returns false because someone else has it or it
  # has already gone out. The compare-and-swap on +updated_at+ is what makes it exclusive: two
  # workers that read the same row both try to spend the same attempt, and only one update matches.
  #
  # This is a claim, not a lease — if the winner dies mid-send, the row keeps no failure, so the
  # sweep picks it up again after +UNATTEMPTED_GRACE+ rather than staying stuck.
  def claim_for_delivery!
    claimed = self.class.where(id: id, sent_at: nil, updated_at: updated_at)
                  .update_all(send_attempts: send_attempts + 1, updated_at: Time.current)
    return false unless claimed == 1

    reload
    true
  end

  private

  def retry_interval
    self.class.retry_interval_for(send_attempts)
  end
end
