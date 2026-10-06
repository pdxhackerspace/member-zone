module Credentials
  # Member emails about their credentials. They name the provider, label and dates and link
  # to the credentials page; they never carry a secret, or a hint of one. Sending goes
  # through QueuedMail so notification opt-outs (Notifications::DeliveryGate) and the mail
  # queue apply as for every other member email.
  module Notifier
    REVOKED_REASONS = {
      'member_inactive' => 'your membership is no longer active',
      'key_access_paused' => 'your key access is paused',
      'revoked_by_admin' => 'an administrator revoked it'
    }.freeze

    module_function

    def expiring_soon(credential)
      enqueue(:credential_expiring_soon, credential.user, credential_name: credential.notice_name,
                                                          credential_expires_at: format_time(credential.expires_at))
    end

    def expired(credential)
      enqueue(:credential_expired, credential.user, credential_name: credential.notice_name,
                                                    credential_expires_at: format_time(credential.expires_at))
    end

    def revoked(user, credentials, reason:)
      enqueue(:credentials_revoked, user, credential_names: credentials.map(&:notice_name),
                                          credential_reason: REVOKED_REASONS.fetch(reason.to_s, 'it was needed'))
    end

    def format_time(time)
      time&.strftime('%B %-d, %Y')
    end

    def enqueue(action, user, **extra_args)
      QueuedMail.enqueue(action, user, **extra_args)
    rescue StandardError => e
      Rails.logger.error("[Credentials::Notifier] could not queue #{action}: #{e.class}")
      nil
    end
  end
end
