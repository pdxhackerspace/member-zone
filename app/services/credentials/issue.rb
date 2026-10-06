module Credentials
  # Issues a credential to a member: checks the rules, records a `pending` row, asks the
  # provider's program for the credential and keeps only what the row is allowed to hold.
  #
  # The plaintext fields come back in the Result and nowhere else — not in the database, a
  # job argument, the log or an email. The caller shows them once, in the response to the
  # request that asked.
  #
  # When the program's output is malformed but still names the credential it created, the
  # credential is revoked straight away rather than left behind at the provider.
  class Issue
    GENERIC_FAILURE = 'The credential could not be issued. Please try again, or ask an administrator.'.freeze

    Result = Struct.new(:ok, :credential, :fields, :error, :detail, :duplicate, :warning, keyword_init: true) do
      alias_method :ok?, :ok
    end

    def self.call(**)
      new(**).call
    end

    # +self_service+ applies the provider's members-may-request rule; it defaults to true when
    # the member is asking for themselves and false when an administrator or the system is.
    # +timeout+ overrides the program's time limit, for callers that need a shorter one.
    # rubocop:disable Metrics/ParameterLists
    def initialize(provider:, user:, issued_by: nil, label: nil, request_id: nil, rotated_from: nil,
                   self_service: nil, timeout: nil)
      # rubocop:enable Metrics/ParameterLists
      @provider = provider
      @user = user
      @issued_by = issued_by
      @label = label.to_s.strip.first(Credential::LABEL_LIMIT).presence
      @request_id = request_id.presence
      @rotated_from = rotated_from
      @self_service = self_service.nil? ? issued_by == user : self_service
      @timeout = timeout
    end

    def call
      return failure('That request is not valid.') if @request_id && !Credential::UUID_FORMAT.match?(@request_id)
      return failure('That request was already submitted.', duplicate: true) if duplicate?

      credential, reason = reserve
      return failure(reason) if reason

      run(credential)
    rescue ActiveRecord::RecordNotUnique
      failure('That request was already submitted.', duplicate: true)
    end

    private

    def duplicate?
      @request_id && Credential.exists?(request_id: @request_id)
    end

    # The limit check and the pending row happen under a lock on the member, so two requests
    # at once cannot both slip under max_per_member.
    def reserve
      @user.with_lock do
        reason = denial_reason
        return [nil, reason] if reason

        [Credential.create!(credential_provider: @provider, user: @user, issued_by: @issued_by, label: @label,
                            request_id: @request_id, rotated_from: @rotated_from, status: 'pending'), nil]
      end
    end

    def denial_reason
      if @self_service
        @provider.self_service_denial_reason(@user, replacing: @rotated_from)
      else
        @provider.issue_denial_reason(@user, replacing: @rotated_from)
      end
    end

    def run(credential)
      outcome = Invocation.call(@provider, 'issue', credential: credential, input: payload(credential),
                                                    timeout: @timeout) do |stdout|
        Protocol.issue(stdout, @provider.schema_fields)
      end
      outcome.ok? ? record(credential, outcome) : abandon(credential, outcome)
    end

    def payload(credential)
      JSON.generate(request_id: credential.request_id, label: credential.label.to_s,
                    member: MemberPayload.call(@user))
    end

    def record(credential, outcome)
      issued = outcome.value
      credential.update!(status: 'active', external_id: issued[:external_id], expires_at: issued[:expires_at],
                         issued_at: Time.current,
                         field_hints: FieldHints.call(issued[:fields], @provider.schema_fields))
      credential.journal!('credential_issued', actor: @issued_by, extra: journal_extra)
      Result.new(ok: true, credential: credential, fields: issued[:fields])
    rescue ActiveRecord::ActiveRecordError => e
      cleanup(credential, issued[:external_id])
      failure(GENERIC_FAILURE, credential: credential, detail: e.class.name)
    end

    def abandon(credential, outcome)
      external_id = Protocol.external_id_from(outcome.stdout) if outcome.stdout.present?
      cleanup(credential, external_id)
      failure(GENERIC_FAILURE, credential: credential, detail: outcome.error)
    end

    # The program may have created something even though we could not use its answer. If it
    # told us what, revoke it; if that fails the credential stays `revoke_failed`, which is
    # retried and flagged, instead of vanishing as `failed`.
    def cleanup(credential, external_id)
      if external_id.present?
        credential.update_columns(external_id: external_id, status: 'revoke_failed',
                                  revocation_reason: 'issue_incomplete', updated_at: Time.current)
        return unless Revoke.call(credential, reason: 'issue_incomplete', journal: false).ok?
      end

      credential.update_columns(status: 'failed', updated_at: Time.current)
    end

    def journal_extra
      @rotated_from ? { rotated_from: @rotated_from.id } : {}
    end

    def failure(message, credential: nil, detail: nil, duplicate: false)
      Result.new(ok: false, error: message, credential: credential, detail: detail, duplicate: duplicate)
    end
  end
end
