module Reminders
  # Emails whoever is responsible for each API token that is about to expire. Delivered directly
  # rather than through the mail queue: the recipients are often staff, and the warning is only
  # useful if it arrives before the token stops working.
  class NotifyApiTokenExpiry
    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      return unless ApiTokenExpiryEligibility.reminder_enabled?

      ApiTokenExpiryEligibility.due(now: @now).each { |token| notify(token) }
    end

    private

    def notify(token)
      token.with_lock do
        return unless ApiTokenExpiryEligibility.due?(token, now: @now)

        ApiTokenExpiryEligibility.recipients(token).each do |recipient|
          MemberMailer.api_token_expiring_soon(recipient, api_token_id: token.id).deliver_later
        end
        ApiTokenExpiryEligibility.record_delivery!(token, at: @now)
      end
    rescue StandardError => e
      Rails.logger.error("[NotifyApiTokenExpiry] api_token_id=#{token.id} failed: #{e.class}: #{e.message}")
    end
  end
end
