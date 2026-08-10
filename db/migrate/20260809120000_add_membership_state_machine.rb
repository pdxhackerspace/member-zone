class AddMembershipStateMachine < ActiveRecord::Migration[8.1]
  # membership_status and dues_status are kept as cached projections of membership_state
  # (see the MembershipState concern), so nothing that reads them needs to change here.
  STATE_BACKFILL = [
    ["membership_status = 'banned'", 'banned_member'],
    ["membership_status = 'deceased'", 'deceased_member'],
    ["membership_status = 'sponsored' OR is_sponsored = TRUE OR payment_type = 'sponsored'", 'sponsored_member'],
    ["membership_status = 'guest'", 'guest_member'],
    ["membership_status = 'applicant'", 'applicant'],
    ["membership_status = 'cancelled'", 'cancelled_member'],
    ["dues_status = 'current'", 'current_member'],
    ["membership_status = 'paying' AND dues_status IN ('lapsed', 'inactive')", 'inactive_member']
  ].freeze

  def up
    add_column :users, :membership_state, :string, null: false, default: 'unknown'
    add_column :users, :membership_state_entered_at, :datetime
    add_column :users, :payment_overdue_reminder_sent_at, :datetime
    add_column :users, :membership_cancelled_email_sent_at, :datetime
    add_index :users, :membership_state
    add_index :users, %i[membership_state membership_state_entered_at]

    add_column :membership_settings, :new_member_grace_period_days, :integer, null: false, default: 14
    add_column :membership_settings, :new_member_expiry_days, :integer, null: false, default: 90
    add_column :membership_settings, :overdue_grace_period_days, :integer, null: false, default: 30
    add_column :membership_settings, :payment_overdue_reminder_repeat_days, :integer, null: false, default: 7
    add_reference :membership_settings, :building_access_training_topic, foreign_key: { to_table: :training_topics }

    change_column_default :membership_settings, :reactivation_grace_period_months, from: 3, to: 12

    backfill_membership_state
  end

  def down
    remove_reference :membership_settings, :building_access_training_topic, foreign_key: { to_table: :training_topics }
    remove_column :membership_settings, :payment_overdue_reminder_repeat_days
    remove_column :membership_settings, :overdue_grace_period_days
    remove_column :membership_settings, :new_member_expiry_days
    remove_column :membership_settings, :new_member_grace_period_days
    change_column_default :membership_settings, :reactivation_grace_period_months, from: 12, to: 3

    remove_index :users, %i[membership_state membership_state_entered_at]
    remove_index :users, :membership_state
    remove_column :users, :membership_cancelled_email_sent_at
    remove_column :users, :payment_overdue_reminder_sent_at
    remove_column :users, :membership_state_entered_at
    remove_column :users, :membership_state
  end

  private

  # Ordered most-specific first; each row takes the first rule it matches, so anything
  # left over stays 'unknown'. Terminal and sponsored states win over payment history.
  def backfill_membership_state
    STATE_BACKFILL.each do |condition, state|
      execute(<<~SQL.squish)
        UPDATE users
        SET membership_state = #{connection.quote(state)}
        WHERE membership_state = 'unknown' AND (#{condition})
      SQL
    end

    execute(<<~SQL.squish)
      UPDATE users
      SET membership_state_entered_at = COALESCE(membership_start_date::timestamp, created_at)
      WHERE membership_state_entered_at IS NULL
    SQL
  end
end
