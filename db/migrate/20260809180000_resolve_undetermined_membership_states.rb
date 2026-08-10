class ResolveUndeterminedMembershipStates < ActiveRecord::Migration[8.1]
  # AddMembershipStateMachine could only classify a member if their old membership_status
  # or dues_status said something. A member the Authentik sync created, or one an admin
  # added by hand, had both sitting on 'unknown' and matched none of the eight rules — so
  # someone who joined, took building access training, and never paid came out
  # 'undetermined' rather than what they plainly are, which is inactive.
  #
  # 'unknown' now means only what it says: a legacy import nobody has reconciled. A real
  # member record with nothing paying for them is inactive_member, which is the same rule
  # User#state_from_payment_history applies when a ban or a sponsorship is lifted.
  #
  # Unlike the applicants RetireApplicantMembershipState sorts out, these members were
  # never approved through the application flow, so there is no onboarding clock to
  # respect and no reason to route any of them through new_member.

  # Matches User#payment_currency_window for a member with no plan. Members with a plan
  # have dues_due_at set, which takes precedence.
  PLANLESS_PAYMENT_WINDOW_DAYS = 32

  RESOLVE_SQL = <<~SQL.squish
    UPDATE users AS u
    SET membership_state = r.state,
        membership_state_entered_at = COALESCE(u.membership_state_entered_at, u.created_at),
        membership_status = 'paying',
        dues_status = CASE WHEN r.state = 'inactive_member' THEN 'lapsed' ELSE 'current' END,
        active = CASE
                   WHEN u.emergency_active_override THEN TRUE
                   WHEN r.state = 'inactive_member' THEN FALSE
                   ELSE TRUE
                 END
    FROM (
      SELECT users.id,
             CASE
               WHEN paid.through IS NOT NULL AND paid.through > NOW() THEN 'current_member'
               ELSE 'inactive_member'
             END AS state
      FROM users
      CROSS JOIN LATERAL (
        SELECT COALESCE(
                 users.dues_due_at,
                 GREATEST(users.last_payment_date::timestamp, users.recharge_most_recent_payment_date)
                   + (#{PLANLESS_PAYMENT_WINDOW_DAYS} * INTERVAL '1 day')
               ) AS through
      ) AS paid
      WHERE users.membership_state = 'unknown'
        AND users.legacy = FALSE
        AND users.service_account = FALSE
    ) AS r
    WHERE u.id = r.id
  SQL

  def up
    execute(RESOLVE_SQL)
  end

  # Which of these were undetermined before is not recoverable, and raising would block
  # rolling back the migration that adds the column this one writes to.
  def down; end
end
