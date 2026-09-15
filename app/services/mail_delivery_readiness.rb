# Whether Action Mailer could plausibly hand a message to a server right now.
#
# Only SMTP delivery can be switched off in practice: production reads its host from
# +SMTP_ADDRESS+ and falls back to a placeholder when that is unset, which is the state the admin
# UI calls "email delivery is disabled". letter_opener, letter_opener_web, and :test never touch
# the network, so they are always ready.
#
# Credentials are deliberately not part of the answer — a relay that accepts unauthenticated mail
# is a valid setup, and a server that refuses the message is handled by the delivery failure path
# instead. +ApplicationHelper#smtp_configured?+ is the stricter question of whether an admin should
# be offered a "send now" button.
class MailDeliveryReadiness
  PLACEHOLDER_SMTP_ADDRESS = 'smtp.example.com'.freeze

  def self.available?
    unavailable_reason.nil?
  end

  # Returns nil when mail can be attempted, otherwise a sentence naming what is missing.
  def self.unavailable_reason
    return nil unless smtp_delivery?

    address = smtp_settings[:address].to_s.strip
    return 'email delivery is disabled: no SMTP server is configured' if address.blank?
    return 'email delivery is disabled: SMTP_ADDRESS is still the placeholder host' if placeholder?(address)

    nil
  end

  def self.smtp_delivery?
    Rails.configuration.action_mailer.delivery_method.to_s == 'smtp'
  end

  def self.smtp_settings
    settings = Rails.configuration.action_mailer.smtp_settings
    settings.is_a?(Hash) ? settings.symbolize_keys : {}
  end

  def self.placeholder?(address)
    address == PLACEHOLDER_SMTP_ADDRESS
  end

  private_class_method :smtp_delivery?, :smtp_settings, :placeholder?
end
