class RetireApplicantMembershipState < ActiveRecord::Migration[8.1]
  # No user was ever legitimately an applicant. A membership application only becomes a
  # User when it is approved, and the state machine moves that user straight to
  # new_member, so 'applicant' existed for one line of FinalizeApproval and is now gone
  # from the enum entirely.
  #
  # What the rows holding it actually are: users created at approval under the old code,
  # which set membership_status = 'applicant' and never moved them off it. So they are
  # approved members who never paid — new_member — except for the ones who did pay, whom
  # AddMembershipStateMachine mis-sorted by testing membership_status before dues.
  # dues_status cannot be consulted now (it is a projection, rewritten to 'unknown' for
  # these rows on any save since), so payment evidence is read from the payment columns,
  # which nothing projects over.
  #
  # Deadlines are resolved here rather than left to Membership::TickJob. Someone approved
  # three years ago who never paid belongs in inactive_member, and letting the job
  # discover that would queue every one of them a membership_lapsed email.
  DEFAULT_NEW_MEMBER_EXPIRY_DAYS = 90

  # Matches User#payment_currency_window for a member with no plan. Members with a plan
  # have dues_due_at set, which takes precedence.
  PLANLESS_PAYMENT_WINDOW_DAYS = 32

  def up
    execute(resolve_applicants_sql(configured_new_member_expiry_days))
  end

  # Deliberately a no-op rather than irreversible: which of these members were formerly
  # labelled applicants is not recoverable, and raising here would block rolling back
  # AddMembershipStateMachine, which drops the column this migration writes to.
  def down; end

  private

  # The setting is the authority, but it does not exist yet on a database migrating from
  # scratch in a single run — where there are no applicant rows to fix either.
  def configured_new_member_expiry_days
    select_value('SELECT new_member_expiry_days FROM membership_settings LIMIT 1') ||
      DEFAULT_NEW_MEMBER_EXPIRY_DAYS
  end

  def resolve_applicants_sql(expiry_days)
    <<~SQL.squish
      UPDATE users AS u
      SET membership_state = r.state,
          membership_state_entered_at = COALESCE(u.membership_state_entered_at, u.created_at),
          membership_status = 'paying',
          dues_status = CASE WHEN r.state = 'inactive_member' THEN 'lapsed' ELSE 'current' END,
          active = CASE
                     WHEN u.service_account THEN u.active
                     WHEN u.emergency_active_override THEN TRUE
                     WHEN r.state = 'inactive_member' THEN FALSE
                     ELSE TRUE
                   END
      FROM (#{resolved_states_sql(expiry_days)}) AS r
      WHERE u.id = r.id
    SQL
  end

  # A paid-through date in the future means they were paying and the original backfill
  # mislabelled them; one in the past means they lapsed. With no payment at all, the
  # new-member expiry decides whether they are still onboarding or long gone.
  def resolved_states_sql(expiry_days)
    <<~SQL.squish
      SELECT users.id,
             CASE
               WHEN paid.through IS NOT NULL AND paid.through > NOW() THEN 'current_member'
               WHEN paid.through IS NOT NULL THEN 'inactive_member'
               WHEN COALESCE(users.membership_state_entered_at, users.created_at)
                      + (#{expiry_days.to_i} * INTERVAL '1 day') > NOW() THEN 'new_member'
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
      WHERE users.membership_state = 'applicant'
    SQL
  end
end
