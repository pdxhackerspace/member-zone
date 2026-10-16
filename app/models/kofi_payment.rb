class KofiPayment < ApplicationRecord
  include NormalizesEmail
  include SensitiveFields

  encrypts_sensitive_string :email
  encrypts_sensitive_json :raw_attributes
  has_email_lookup :email, digest_column: :email_lookup_digest
  normalizes_email_field :email

  belongs_to :user, optional: true
  belongs_to :sheet_entry, optional: true
  has_many :payment_events, dependent: :nullify

  validates :kofi_transaction_id, presence: true, uniqueness: true

  scope :ordered, -> { order(timestamp: :desc, created_at: :desc) }
  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :for_sheet_entry, ->(entry) { where(sheet_entry_id: entry.id) }
  scope :search, lambda { |term|
    pattern = "%#{term.to_s.downcase}%"
    # Encrypted emails match only on a whole address, via their lookup digest.
    digest = SensitiveData.email_digest(term)
    left_joins(:user).where(
      "LOWER(COALESCE(kofi_payments.kofi_transaction_id, '')) LIKE :q " \
      "OR LOWER(COALESCE(kofi_payments.from_name, '')) LIKE :q " \
      "OR LOWER(COALESCE(kofi_payments.payment_type, '')) LIKE :q " \
      "OR LOWER(COALESCE(kofi_payments.tier_name, '')) LIKE :q " \
      "OR LOWER(COALESCE(kofi_payments.message, '')) LIKE :q " \
      "OR LOWER(COALESCE(kofi_payments.status, '')) LIKE :q " \
      "OR LOWER(COALESCE(users.full_name, '')) LIKE :q " \
      'OR kofi_payments.email_lookup_digest = :d ' \
      'OR users.email_lookup_digest = :d',
      q: pattern, d: digest
    )
  }

  def amount_with_currency
    return nil if amount.blank?

    "#{format('%.2f', amount)} #{currency}"
  end

  def identifier
    kofi_transaction_id
  end

  def processed_time
    timestamp
  end
end
