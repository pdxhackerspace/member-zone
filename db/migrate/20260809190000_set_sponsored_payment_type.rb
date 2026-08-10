class SetSponsoredPaymentType < ActiveRecord::Migration[8.1]
  # A sponsored member is not missing a payment type. Somebody else covers them, and
  # 'sponsored' says so — leaving them on 'unknown' put them in the "Payment type
  # unknown" report, which is meant to surface members nobody is billing by accident.
  #
  # MembershipStateProjection now dictates this on every save, so this is only catching
  # up the rows that predate it. Members flagged is_sponsored who are *not* in the
  # sponsored_member state are deliberately left alone: that contradiction is what the
  # "Sponsored and paying" report exists to surface.
  def up
    execute(<<~SQL.squish)
      UPDATE users
      SET payment_type = 'sponsored'
      WHERE membership_state = 'sponsored_member'
        AND payment_type IS DISTINCT FROM 'sponsored'
        AND service_account = FALSE
    SQL
  end

  # What each of these was before is not recorded, and 'unknown' is not a safe guess for
  # all of them.
  def down; end
end
