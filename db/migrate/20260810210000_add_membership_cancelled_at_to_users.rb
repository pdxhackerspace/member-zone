# "They cancelled" outlives cancelled_member. Once a member's paid-through date passes they
# become inactive like anyone else who stopped paying, and the state alone cannot tell the
# two apart — so we mail a lapse notice to someone who chose to leave and told us so.
#
# The date is remembered on its own column, cleared when they come back.
class AddMembershipCancelledAtToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :membership_cancelled_at, :datetime
    add_index :users, :membership_cancelled_at

    # Members sitting in cancelled_member entered it when they cancelled, so their existing
    # stamp is the date. Members who already expired past it are recovered from the payment
    # event ledger by Membership::CancellationReconciler, which knows how to tell a
    # cancellation from a resubscription.
    execute(<<~SQL.squish)
      UPDATE users
      SET membership_cancelled_at = COALESCE(membership_state_entered_at, updated_at)
      WHERE membership_state = 'cancelled_member'
    SQL
  end

  def down
    remove_index :users, :membership_cancelled_at
    remove_column :users, :membership_cancelled_at
  end
end
