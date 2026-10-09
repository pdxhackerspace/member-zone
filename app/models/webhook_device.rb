# A piece of hardware — an access control kiosk, a badge reader — that is allowed to call
# Member Zone's device webhooks, such as issuing a parking permit for the member who badged in.
#
# Each device holds its own bearer token. Only a SHA-256 digest is stored: the plaintext is shown
# once, when the device is created or its token is regenerated, and is never recoverable after
# that. The last four characters are kept so admins can tell which token a device is using.
class WebhookDevice < ApplicationRecord
  TOKEN_BYTES = 32

  has_many :parking_notices, dependent: :nullify
  has_many :parking_permit_links, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :token_digest, presence: true, uniqueness: true

  before_validation :issue_token, on: :create

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(:name) }

  # The plaintext token, available only on the instance that generated it.
  attr_reader :token

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token.to_s)
  end

  # The enabled device holding +token+, or nil. Lookup is by digest, so the comparison happens in
  # the database index rather than in Ruby and leaks nothing about near-misses.
  def self.authenticate(token)
    return nil if token.blank?

    enabled.find_by(token_digest: digest(token))
  end

  def regenerate_token!
    issue_token
    save!
    token
  end

  def record_use!(ip:)
    update_columns(last_used_at: Time.current, last_used_ip: ip.to_s.first(64), updated_at: Time.current)
  end

  private

  def issue_token
    @token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    self.token_digest = self.class.digest(@token)
    self.token_hint = @token.last(4)
  end
end
