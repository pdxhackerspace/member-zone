module Credentials
  # The daily backstop for everything the event-driven paths can miss (a user updated with
  # update_columns, a job lost from Redis, a provider that was down):
  #
  #   - members whose credentials no longer match their standing are synced again;
  #   - credentials stuck in `revoke_failed` are retried, backing off exponentially to a day;
  #   - `pending` rows that never heard back from their program are marked `failed`.
  #
  # With +dry_run+ it reports what it would do and changes nothing.
  class Reconciler
    BACKOFF_BASE = 1.hour
    BACKOFF_CAP = 24.hours

    Report = Struct.new(:users, :retried, :stale, keyword_init: true)

    def self.call(dry_run: false, now: Time.current)
      new(dry_run, now).call
    end

    # How long to wait after the +attempts+th failed revoke before trying again.
    def self.backoff(attempts)
      [BACKOFF_BASE * (2**[attempts - 1, 0].max), BACKOFF_CAP].min
    end

    def initialize(dry_run, now)
      @dry_run = dry_run
      @now = now
    end

    def call
      users = mismatched_users
      users.each { |user| MemberSync.call(user) } unless @dry_run
      retries = due_for_retry
      retries.each { |credential| retry_revoke(credential) } unless @dry_run
      stale = Credential.stale_pending.to_a
      stale.each { |credential| abandon(credential) } unless @dry_run
      Report.new(users: users, retried: retries, stale: stale)
    end

    private

    def mismatched_users
      ids = Credential.where(status: %w[active paused revoke_failed]).select(:user_id)
      User.where(id: ids).includes(:credentials).select { |user| mismatch?(user) }
    end

    def mismatch?(user)
      statuses = user.credentials.map(&:status)
      return statuses.intersect?(Credential::LIVE_STATUSES) unless user.active?
      return statuses.include?('active') if user.key_access_paused?

      statuses.include?('paused')
    end

    def due_for_retry
      Credential.revoke_failed.includes(:credential_provider, :user).select do |credential|
        credential.last_revoke_error_at.nil? ||
          credential.last_revoke_error_at + self.class.backoff(credential.revoke_attempts) <= @now
      end
    end

    def retry_revoke(credential)
      credential.reload
      return unless credential.revoke_failed?

      Revoke.call(credential, reason: credential.revocation_reason || 'member_inactive', by: credential.revoked_by)
    end

    def abandon(credential)
      credential.update!(status: 'failed')
      credential.journal!('credential_issue_incomplete')
    end
  end
end
