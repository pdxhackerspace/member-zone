module Credentials
  # Suspends an active credential at a provider whose program supports `pause` and `resume`.
  # A failure leaves the credential `active`; Credentials::ReconcileJob tries again.
  class Pause
    def self.call(credential, reason: 'key_access_paused', by: nil)
      new(credential, reason, by).call
    end

    def initialize(credential, reason, by)
      @credential = credential
      @reason = reason
      @by = by
    end

    def call
      provider = @credential.credential_provider
      return refuse('This credential is not active.') unless @credential.active?
      return refuse('This provider cannot pause credentials.') unless provider.supports_pause?

      outcome = Invocation.call(provider, 'pause', credential: @credential,
                                                   input: MemberPayload.for_credential(@credential, @reason)) { true }
      return refuse(outcome.error) unless outcome.ok?

      @credential.update!(status: 'paused', paused_at: Time.current)
      @credential.journal!('credential_paused', actor: @by)
      ActionResult.new(ok: true, credential: @credential)
    end

    private

    def refuse(message)
      ActionResult.new(ok: false, error: message, credential: @credential)
    end
  end
end
