# A short-lived, no-login link that lets a member fill in a parking permit and print it.
#
# Links come from device webhooks. A +create_permit+ link creates a new permit when the member
# submits the form; a +complete_permit+ link fills in the details of a blank permit the device
# already issued. Either way the link only ever touches that one permit — it does not sign
# anybody in.
#
# The token itself is never stored, only its digest, so a database leak does not hand out
# working links.
class ParkingPermitLink < ApplicationRecord
  LIFETIME = 12.hours
  TOKEN_BYTES = 32
  PURPOSES = %w[create_permit complete_permit].freeze

  belongs_to :user
  belongs_to :webhook_device, optional: true
  belongs_to :parking_notice, optional: true

  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validates :purpose, inclusion: { in: PURPOSES }
  validates :parking_notice, presence: true, if: :complete_permit?

  before_validation :issue_token, on: :create

  attr_reader :token

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token.to_s)
  end

  def self.for_token(token)
    return nil if token.blank?

    find_by(token_digest: digest(token))
  end

  def self.issue_for_new_permit!(user:, webhook_device: nil, now: Time.current)
    create!(purpose: 'create_permit', user: user, webhook_device: webhook_device, expires_at: now + LIFETIME)
  end

  def self.issue_for_blank_permit!(parking_notice, now: Time.current)
    create!(purpose: 'complete_permit', parking_notice: parking_notice, user: parking_notice.user,
            webhook_device: parking_notice.webhook_device, expires_at: now + LIFETIME)
  end

  def create_permit?
    purpose == 'create_permit'
  end

  def complete_permit?
    purpose == 'complete_permit'
  end

  def expired?(now: Time.current)
    expires_at <= now
  end

  # A link that creates a permit can be used once; afterwards it only shows the permit it made.
  def submitted?
    submitted_at.present?
  end

  # Whether the form should still accept input: the link is live, and either it completes a blank
  # permit that is still active (members may correct what they wrote while the link lasts) or it
  # has not created its permit yet.
  def editable?(now: Time.current)
    return false if expired?(now: now)
    return parking_notice&.active? == true if complete_permit?

    !submitted?
  end

  # The permit can be printed from the link while the link is live and the permit is active.
  def printable?(now: Time.current)
    !expired?(now: now) && parking_notice&.active? == true
  end

  def url
    Rails.application.routes.url_helpers.parking_permit_form_url(
      token: token, **Rails.application.config.action_mailer.default_url_options
    )
  end

  private

  def issue_token
    @token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    self.token_digest = self.class.digest(@token)
  end
end
