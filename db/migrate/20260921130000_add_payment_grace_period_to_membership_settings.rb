class AddPaymentGracePeriodToMembershipSettings < ActiveRecord::Migration[8.1]
  # RemoveReminderTimingFromMembershipSettings dropped a payment_grace_period_days that the
  # form had always offered and nothing had ever read. This one is wired to the state
  # machine: a current member keeps that standing until their dues date plus this many days,
  # which is the window a payment has to clear its processor and reach us through a sync.
  # Without it, the tick job moves a member out of current_member at 4 AM on the morning
  # their dues fall due, hours before anything could tell us they had paid.
  #
  # Five days rather than the fourteen the dead column defaulted to: overdue_member is what
  # carries a member who is genuinely late, and this only has to outlast a card retry.
  def change
    add_column :membership_settings, :payment_grace_period_days, :integer, null: false, default: 5
  end
end
