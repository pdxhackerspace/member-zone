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
      rotation_denial_reason || provider_denial_reason
    end

    # Runs under the member lock, so of two rotations of one credential submitted together
    # only the first gets a pending replacement; the second sees it and stops here, rather
    # than both leaving the original out of the limit count and both succeeding.
    def rotation_denial_reason
      return nil unless @rotated_from
      return 'This credential is already being replaced.' if replacement_in_progress?
      return 'This credential cannot be rotated.' unless @rotated_from.reload.active?

      nil
    end

    def replacement_in_progress?
      Credential.where(rotated_from: @rotated_from).counting_toward_limit.exists?
    end

    def provider_denial_reason
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
      return withdrawn(credential) unless still_in_standing?

      Result.new(ok: true, credential: credential, fields: issued[:fields])
    rescue ActiveRecord::ActiveRecordError => e
      cleanup(credential, issued[:external_id])
      failure(GENERIC_FAILURE, credential: credential, detail: e.class.name)
    end

    # Standing was checked before the program ran, but a member banned, lapsed or paused while
    # it was running would otherwise walk away with a working credential: the save hook that
    # syncs credentials saw only this pending row. Re-read the member now and bring every
    # credential of theirs into line before deciding whether to show this one.
    def still_in_standing?
      @user.reload
      @user.active? && !@user.key_access_paused?
    end

    # This one is revoked first, then MemberSync brings the member's others into line. Left to
    # MemberSync it would be paused where the provider can pause, but a credential the member
    # was never shown is no use to them paused.
    def withdrawn(credential)
      reason = @user.active? ? 'key_access_paused' : 'member_inactive'
      Revoke.call(credential, reason: reason)
      MemberSync.call(@user)
      failure(GENERIC_FAILURE, credential: credential.reload,
                               detail: 'Member standing changed while the credential was being issued')
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
