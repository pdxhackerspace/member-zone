class ApplicationVerification < ApplicationRecord
  include SensitiveFields

  encrypts_sensitive_string :email
  has_email_lookup :email, digest_column: :email_lookup_digest

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :token, presence: true, uniqueness: true

  before_validation :generate_token, on: :create
  before_validation :set_expiry, on: :create

  scope :active, -> { where(email_verified: true).where('expires_at > ?', Time.current) }
  scope :newest_first, -> { order(created_at: :desc) }
  scope :admin_search, lambda { |query|
    raw = query.to_s.strip
    raw.blank? ? all : by_email(raw)
  }

  def expired?
    expires_at < Time.current
  end

  def verified?
    email_verified? && !expired?
  end

  def verify_email!
    update!(email_verified: true, verified_at: Time.current)
  end

  def extend_expiration_by!(duration)
    update!(expires_at: [expires_at, Time.current].max + duration)
  end

  def received_application?
    MembershipApplication.where.not(status: 'draft')
                         .merge(MembershipApplication.by_email(email))
                         .exists?
  end

  def awaiting_application?
    !received_application?
  end

  def submitted_application
    MembershipApplication.where.not(status: 'draft')
                         .merge(MembershipApplication.by_email(email))
                         .newest_first
                         .first
  end

  def status_link?
    submitted_application.present?
  end

  def deliver_verification_email!
    return if Notifications::DeliveryGate.blocked?(mailer_action: 'application_email_verification', email: email)

    url_options = Rails.application.config.action_mailer.default_url_options
    verification_url = Rails.application.routes.url_helpers.apply_verify_email_url(
      token: token,
      **url_options
    )
    expiry_hours = MembershipSetting.application_verification_expiry_hours

    MemberMailer.application_email_verification(
      email,
      verification_url: verification_url,
      expires_in: "#{expiry_hours} #{'hour'.pluralize(expiry_hours)}",
      verification_token: token
    ).deliver_later
  end

  def status_display
    return 'Expired' if expired?
    return 'Verified' if email_verified?

    'Email sent'
  end

  private

  def generate_token
    self.token ||= SecureRandom.alphanumeric(32)
  end

  def set_expiry
    self.expires_at ||= MembershipSetting.application_verification_expiry_hours.hours.from_now
  end
end
