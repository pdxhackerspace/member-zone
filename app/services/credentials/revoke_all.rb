module Credentials
  # Revokes every credential in a scope (a provider's, or one member's), telling each affected
  # member once. With +dry_run+ it only reports what it would revoke.
  class RevokeAll
    Report = Struct.new(:revoked, :failed, :candidates, keyword_init: true)

    def self.call(scope, reason: 'revoked_by_admin', by: nil, dry_run: false, notify: true)
      new(scope, reason, by, dry_run, notify).call
    end

    def initialize(scope, reason, by, dry_run, notify)
      @candidates = scope.live.includes(:credential_provider, :user).to_a
      @reason = reason
      @by = by
      @dry_run = dry_run
      @notify = notify
    end

    def call
      report = Report.new(revoked: [], failed: [], candidates: @candidates)
      return report if @dry_run

      @candidates.each do |credential|
        result = Revoke.call(credential, reason: @reason, by: @by)
        (result.ok? ? report.revoked : report.failed) << credential
      end
      notify_members(report.revoked) if @notify
      report
    end

    private

    def notify_members(revoked)
      revoked.group_by(&:user).each { |user, credentials| Notifier.revoked(user, credentials, reason: @reason) }
    end
  end
end
