module Credentials
  # Brings a member's credentials in line with their standing:
  #
  #   - not an active member: every live credential is revoked;
  #   - key access paused: active credentials are paused, or revoked where the provider's
  #     program cannot pause;
  #   - active and not paused: paused credentials are resumed.
  #
  # Revoking is reported to the member by email. Anything that fails is left for
  # Credentials::ReconcileJob to try again.
  class MemberSync
    Summary = Struct.new(:revoked, :paused, :resumed, :failed, keyword_init: true)

    def self.call(user)
      new(user).call
    end

    def initialize(user)
      @user = user
      @summary = Summary.new(revoked: [], paused: [], resumed: [], failed: [])
    end

    def call
      if !@user.active?
        revoke_each(@user.credentials.live, 'member_inactive')
      elsif @user.key_access_paused?
        pause_each
      else
        resume_each
      end
      notify_revoked
      @summary
    end

    private

    def revoke_each(scope, reason)
      scope.includes(:credential_provider).find_each do |credential|
        result = Revoke.call(credential, reason: reason)
        (result.ok? ? @summary.revoked : @summary.failed) << credential
        @revoked_reason = reason if result.ok?
      end
    end

    def pause_each
      @user.credentials.where(status: 'active').includes(:credential_provider).find_each do |credential|
        if credential.credential_provider.supports_pause?
          result = Pause.call(credential)
          (result.ok? ? @summary.paused : @summary.failed) << credential
        else
          revoke_each(Credential.where(id: credential.id), 'key_access_paused')
        end
      end
    end

    def resume_each
      @user.credentials.where(status: 'paused').includes(:credential_provider).find_each do |credential|
        result = Resume.call(credential)
        (result.ok? ? @summary.resumed : @summary.failed) << credential
      end
    end

    def notify_revoked
      return if @summary.revoked.empty?

      Notifier.revoked(@user, @summary.revoked, reason: @revoked_reason)
    end
  end
end
