module Credentials
  # Revokes a credential at its provider. Success makes it `revoked`; failure leaves it
  # `revoke_failed` with the attempt counted, so Credentials::ReconcileJob retries it and the
  # admin dashboard flags it. A disabled or unhealthy provider is still asked to revoke:
  # taking a provider out of service must never leave credentials working.
  class Revoke
    def self.call(credential, reason:, by: nil, journal: true)
      new(credential, reason, by, journal).call
    end

    def initialize(credential, reason, by, journal)
      @credential = credential
      @reason = reason.to_s
      @by = by
      @journal = journal
    end

    def call
      return ActionResult.new(ok: true, credential: @credential) if @credential.revoked?
      return refuse('This credential cannot be revoked.') unless @credential.revocable?

      outcome = Invocation.call(@credential.credential_provider, 'revoke', credential: @credential,
                                                                           input: input) { true }
      outcome.ok? ? succeed : fail_with(outcome.error)
    end

    private

    def input
      MemberPayload.for_credential(@credential, @reason)
    end

    def succeed
      @credential.update!(status: 'revoked', revoked_at: Time.current, revoked_by: @by,
                          revocation_reason: @reason)
      if @journal
        @credential.journal!('credential_revoked', actor: @by,
                                                   extra: { reason: @credential.revocation_reason_label })
      end
      ActionResult.new(ok: true, credential: @credential)
    end

    def fail_with(error)
      @credential.update!(status: 'revoke_failed', revoke_attempts: @credential.revoke_attempts + 1,
                          last_revoke_error_at: Time.current, revocation_reason: @reason, revoked_by: @by)
      if @journal
        @credential.journal!('credential_revoke_failed', actor: @by,
                                                         extra: { error: error.to_s.truncate(300) })
      end
      ActionResult.new(ok: false, error: error, credential: @credential)
    end

    def refuse(message)
      ActionResult.new(ok: false, error: message, credential: @credential)
    end
  end
end
