module Credentials
  # Re-enables a paused credential. A failure leaves it `paused`.
  class Resume
    def self.call(credential, reason: 'key_access_resumed', by: nil)
      new(credential, reason, by).call
    end

    def initialize(credential, reason, by)
      @credential = credential
      @reason = reason
      @by = by
    end

    def call
      return refuse('This credential is not paused.') unless @credential.paused?

      input = MemberPayload.for_credential(@credential, @reason)
      outcome = Invocation.call(@credential.credential_provider, 'resume', credential: @credential,
                                                                           input: input) { true }
      return refuse(outcome.error) unless outcome.ok?

      @credential.update!(status: 'active', paused_at: nil)
      @credential.journal!('credential_resumed', actor: @by)
      ActionResult.new(ok: true, credential: @credential)
    end

    private

    def refuse(message)
      ActionResult.new(ok: false, error: message, credential: @credential)
    end
  end
end
