class LocalAccount < ApplicationRecord
  include SensitiveFields

  encrypts_sensitive_string :email
  has_email_lookup :email, digest_column: :email_lookup_digest

  has_secure_password

  validates :email, presence: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email_lookup_digest, uniqueness: true, allow_blank: true
  validate :email_is_unique
  validates :password, length: { minimum: 12 }, allow_nil: true
  validates :password_digest, presence: true

  scope :active, -> { where(active: true) }

  # `find_or_initialize_by(email:)` cannot work here: the column holds ciphertext, so a
  # plaintext comparison never matches and every caller would build a second account that
  # the digest index then refuses. Look accounts up through the digest instead.
  def self.provision!(email:, password:, full_name: nil, admin: true, active: true)
    account = by_email(email).first || new
    account.assign_attributes(
      email: email,
      password: password,
      password_confirmation: password,
      admin: admin,
      active: active
    )
    account.full_name = full_name if full_name.present?
    account.save!
    account
  end

  # Accounts whose address was encrypted under a different DATABASE_FIELD_ENCRYPTION_KEY than
  # the one now configured. They cannot sign anyone in — the digest they carry was derived
  # from the old EMAIL_LOOKUP_HMAC_KEY too, so `by_email` cannot find them either.
  def self.unreadable
    all.reject(&:email_readable?)
  end

  def email_readable?
    SensitiveData.readable_string?(self[:email])
  end

  def display_name
    full_name.presence || email
  end

  private

  def email_is_unique
    return if email.blank?

    relation = self.class.by_email(email)
    relation = relation.where.not(id: id) if persisted?
    errors.add(:email, :taken) if relation.exists?
  end
end
