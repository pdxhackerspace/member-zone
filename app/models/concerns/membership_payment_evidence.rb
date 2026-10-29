# Whether a payment is news. A charge still inside the billing window is not, by itself,
# a payment that just arrived. It counts when its date is on or after the day the member
# entered their current state, and after the most recent cancellation. Overdue entry is
# stamped at the dues date, and a renewal charge usually carries that same date, so the
# entry day is new evidence. A charge dated before that stamp was already counted. The
# cancellation day is not: the payment is a date and the notice is a timestamp, so the
# two cannot be ordered, which is the same line returned_after? draws.
module MembershipPaymentEvidence
  extend ActiveSupport::Concern

  # Immune states are a hard stop on top, and so is a stray is_sponsored flag that has
  # not yet been pulled back onto sponsored_member.
  def payment_revives?(payment_time)
    return false if payment_time.blank?
    return false if membership_state.in?(User::PAYMENT_IMMUNE_STATES) || is_sponsored?

    paid_on = payment_time.to_date
    return false if before_state_entry?(paid_on)
    return false if on_or_before_cancellation?(paid_on)

    true
  end

  private

  def before_state_entry?(date)
    entered_on = membership_state_entered_at&.to_date
    entered_on.present? && date < entered_on
  end

  def on_or_before_cancellation?(date)
    cancelled_on = latest_cancellation_at&.to_date
    cancelled_on.present? && date <= cancelled_on
  end
end
