# Whether a payment is news. A charge still inside the billing window is not, by itself,
# a payment that just arrived: the date has to be after the member entered their current
# state and after the most recent cancellation. For an expiry-driven inactive member the
# entry stamp is the deadline, so a charge that was already counted can never revive them.
module MembershipPaymentEvidence
  extend ActiveSupport::Concern

  # Immune states are a hard stop on top, and so is a stray is_sponsored flag that has
  # not yet been pulled back onto sponsored_member.
  def payment_revives?(payment_time)
    return false if payment_time.blank?
    return false if membership_state.in?(User::PAYMENT_IMMUNE_STATES) || is_sponsored?

    paid_on = payment_time.to_date
    return false if on_or_before_entry?(paid_on, membership_state_entered_at)
    return false if on_or_before_entry?(paid_on, latest_cancellation_at)

    true
  end

  private

  def on_or_before_entry?(date, moment)
    moment.present? && date <= moment.to_date
  end
end
