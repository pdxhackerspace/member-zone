class Current < ActiveSupport::CurrentAttributes
  # The account the request is acting as — the impersonated member during impersonation.
  attribute :user
  # The account actually signed in. Differs from `user` only while impersonating.
  attribute :true_user
  attribute :skip_authentik_sync
  # Set while replaying history. State-entry mail describes something that just happened;
  # a backfill is catching up on something that happened months ago and must stay quiet.
  attribute :skip_membership_state_email

  # Who to name in an audit trail: the human at the keyboard, not the account they are
  # viewing as. Falls back to `user` for system work with no signed-in session.
  def self.actor
    true_user || user
  end

  # Present only when the actor and the account being acted as differ.
  def self.acting_as
    user if true_user && user && true_user != user
  end
end
