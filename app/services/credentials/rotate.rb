module Credentials
  # Replaces a credential: issues a new one with the same label, then revokes the old one,
  # in that order so there is never a gap. The two are linked through rotated_from_id.
  # Returns the Issue result, whose plaintext fields the caller shows once. If the old
  # credential cannot be revoked the new one is still returned, with a warning.
  class Rotate
    # +self_service+ is passed through to Issue; nil lets Issue decide from who is asking.
    def self.call(credential, by:, request_id: nil, self_service: nil)
      new(credential, by, request_id, self_service).call
    end

    def initialize(credential, by, request_id, self_service)
      @credential = credential
      @by = by
      @request_id = request_id
      @self_service = self_service
    end

    def call
      return refuse unless @credential.rotatable?

      result = Issue.call(provider: @credential.credential_provider, user: @credential.user, issued_by: @by,
                          label: @credential.label, request_id: @request_id, rotated_from: @credential,
                          self_service: @self_service)
      return result unless result.ok?

      revoked = Revoke.call(@credential, reason: 'rotated', by: @by)
      result.warning = 'The old credential could not be revoked yet; it will be retried.' unless revoked.ok?
      result
    end

    private

    def refuse
      Issue::Result.new(ok: false, credential: @credential, error: 'This credential cannot be rotated.')
    end
  end
end
