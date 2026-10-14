module Reminders
  # API tokens approaching their expiry. The cadence counts from expires_at — the catalog's start
  # offset is negative, so reminders go out before it — and extending a token moves the anchor,
  # which starts the sequence over for the next expiry.
  #
  # Revoked and suspended tokens are left alone, as are tokens whose holder is inactive: none of
  # them works anyway, and nudging someone to extend one would be noise. An expired token is not
  # reminded either; the reminders exist to head that off, and once it has happened the token
  # pages say so.
  #
  # Who hears about it: the token's contact while they are an active member who can be emailed;
  # otherwise everyone who manages tokens, so a service account's token is never orphaned by its
  # contact leaving.
  class ApiTokenExpiryEligibility
    extend Cadence

    REMINDER_KEY = 'api_token_expiry'.freeze
    MANAGE_PRIVILEGE = 'api.tokens.manage'.freeze
    ANCHOR_SQL = 'api_tokens.expires_at'.freeze

    def self.reminder_key
      REMINDER_KEY
    end

    def self.anchor(token)
      token.expires_at
    end

    def self.due(now: Time.current)
      ids = candidates(now: now).select { |token| due?(token, now: now) }.map(&:id)
      ApiToken.where(id: ids).includes(:user, :contact_user).order(:expires_at)
    end

    def self.count_due(now: Time.current)
      candidates(now: now).count { |token| due?(token, now: now) }
    end

    # Tokens that will expire within the reminder window, whether or not one is due today.
    def self.total_expiring(now: Time.current)
      remindable_scope(now: now).count
    end

    def self.due?(token, now: Time.current)
      return false if token.revoked? || token.suspended? || token.expired?(now: now)
      return false unless token.user.active?
      return false if recipients(token).empty?

      cadence_due?(token, now: now)
    end

    def self.recipients(token)
      contact = token.contact_user
      return [contact] if contact_reachable?(contact)

      managers
    end

    # Whether the reminder will go to the token managers because nobody on the token can take it.
    def self.contact_unreachable?(token)
      !contact_reachable?(token.contact_user)
    end

    def self.contact_reachable?(contact)
      contact.present? && !contact.service_account? && contact.active? && deliverable?(contact)
    end

    def self.managers
      User.with_privilege(MANAGE_PRIVILEGE).or(User.where(is_admin: true))
          .non_service_accounts.active.to_a.select { |user| deliverable?(user) }
    end

    def self.deliverable?(user)
      user.email.present? && !MailRecipientGuard.blocked?(user)
    end

    def self.candidates(now: Time.current)
      DeliveryScope.candidates(remindable_scope(now: now), key: REMINDER_KEY, anchor_sql: ANCHOR_SQL, now: now)
                   .includes(:user, :contact_user)
    end

    # The furthest a first reminder can be from expiry, from the reminder's own start offset.
    def self.remindable_scope(now: Time.current)
      lead = [-(reminder_setting&.start_offset_days || 0), 0].max.days
      ApiToken.not_revoked.where(suspended_at: nil).where(expires_at: now..(now + lead))
    end

    private_class_method :candidates, :remindable_scope, :deliverable?, :contact_reachable?, :managers
  end
end
