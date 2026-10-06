module Credentials
  # The daily expiry pass. A credential with an expires_at gets one warning email a week
  # ahead, and is marked `expired` once the date passes. Revoke is not called: the date comes
  # from the provider's own program, which enforces it. With +dry_run+ nothing changes.
  class Expirer
    Report = Struct.new(:warned, :expired, keyword_init: true)

    def self.call(dry_run: false, now: Time.current)
      new(dry_run, now).call
    end

    def initialize(dry_run, now)
      @dry_run = dry_run
      @now = now
    end

    def call
      to_expire = Credential.expirable.where(expires_at: ...@now).includes(:credential_provider, :user).to_a
      to_warn = warnable.where.not(id: to_expire.map(&:id)).includes(:credential_provider, :user).to_a
      unless @dry_run
        to_warn.each { |credential| warn(credential) }
        to_expire.each { |credential| expire(credential) }
      end
      Report.new(warned: to_warn, expired: to_expire)
    end

    private

    def warnable
      Credential.expirable.where(expiry_warning_sent_at: nil)
                .where(expires_at: @now..(@now + Credential::EXPIRY_WARNING))
    end

    def warn(credential)
      credential.update_columns(expiry_warning_sent_at: @now, updated_at: @now)
      Notifier.expiring_soon(credential)
    end

    def expire(credential)
      credential.update!(status: 'expired')
      credential.journal!('credential_expired')
      Notifier.expired(credential)
    end
  end
end
