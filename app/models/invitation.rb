class Invitation < ApplicationRecord
  include SensitiveFields

  encrypts_sensitive_string :email
  has_email_lookup :email, digest_column: :email_lookup_digest

  MEMBERSHIP_TYPES = %w[member sponsored guest].freeze

  MEMBERSHIP_TYPE_LABELS = {
    'member' => 'Member',
    'sponsored' => 'Sponsored Member',
    'guest' => 'Guest'
  }.freeze

  MEMBERSHIP_TYPE_DESCRIPTIONS = {
    'member' => 'Full membership — standard dues-paying member account.',
    'sponsored' => 'Sponsored membership — full access including building access, no dues required.',
    'guest' => 'Guest account — Slack access and software services, no building access.'
  }.freeze

  belongs_to :invited_by, class_name: 'User'
  belongs_to :user, optional: true

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :token, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validates :membership_type, presence: true, inclusion: { in: MEMBERSHIP_TYPES }
  validate :email_not_already_registered, on: :create

  before_validation :generate_token, on: :create
  before_validation :set_expiry, on: :create

  scope :pending, -> { where(accepted_at: nil, cancelled_at: nil).where('expires_at > ?', Time.current) }
  scope :expired, -> { where(accepted_at: nil, cancelled_at: nil).where(expires_at: ..Time.current) }
  scope :accepted, -> { where.not(accepted_at: nil) }
  scope :cancelled, -> { where.not(cancelled_at: nil) }
  scope :newest_first, -> { order(created_at: :desc) }

  def pending?
    accepted_at.nil? && cancelled_at.nil? && expires_at > Time.current
  end

  def expired?
    accepted_at.nil? && cancelled_at.nil? && expires_at <= Time.current
  end

  def accepted?
    accepted_at.present?
  end

  def cancelled?
    cancelled_at.present?
  end

  def cancel!
    update!(cancelled_at: Time.current)
  end

  def type_label
    MEMBERSHIP_TYPE_LABELS[membership_type] || membership_type.humanize
  end

  def type_description
    MEMBERSHIP_TYPE_DESCRIPTIONS[membership_type] || ''
  end

  def accept!(new_user)
    transaction do
      apply_membership_type!(new_user)
      update!(accepted_at: Time.current, user: new_user)
    end
  end

  def invitation_url
    "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000')}/invite/#{token}"
  end

  private

  def email_not_already_registered
    return if email.blank?

    existing = User.lookup_by_email(email)
    return unless existing

    errors.add(:email, "is already registered to @#{existing.username}")
  end

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def set_expiry
    self.expires_at ||= Time.current + MembershipSetting.instance.invitation_expiry_hours.hours
  end

  def apply_membership_type!(user)
    case membership_type
    when 'sponsored' then user.mark_sponsored!
    when 'guest' then user.mark_guest!
    end
  end
end
