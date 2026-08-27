class EmailNotificationOptOut < ApplicationRecord
  include SensitiveFields

  encrypts_sensitive_string :email
  has_email_lookup :email, digest_column: :email_lookup_digest

  validates :category, presence: true, inclusion: { in: ->(_) { NotificationCategory::CATALOG.keys } }
  validates :channel, presence: true, inclusion: { in: NotificationCategory::CHANNELS }
  validates :source, presence: true, inclusion: { in: NotificationCategory::SOURCES }
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email_lookup_digest, uniqueness: { scope: %i[category channel] }, allow_blank: true

  scope :for_category, ->(category) { where(category: category) }
  scope :ordered, -> { order(updated_at: :desc) }

  def self.opted_out?(email, category:, channel: 'email')
    normalized = SensitiveData.normalize_email(email)
    return false if normalized.blank?

    digest = SensitiveData.email_digest(normalized)
    return false if digest.blank?

    exists?(email_lookup_digest: digest, category: category, channel: channel)
  end

  def self.opt_out!(email, category:, channel: 'email', source: 'email_link')
    normalized = SensitiveData.normalize_email(email)
    digest = SensitiveData.email_digest(normalized)
    raise ActiveRecord::RecordInvalid if digest.blank?

    record = find_or_initialize_by(email_lookup_digest: digest, category: category, channel: channel)
    record.email = normalized
    record.source = source
    record.save!
    record
  end

  def self.opt_in!(email, category:, channel: 'email')
    normalized = SensitiveData.normalize_email(email)
    digest = SensitiveData.email_digest(normalized)
    return 0 if digest.blank?

    where(email_lookup_digest: digest, category: category, channel: channel).delete_all
  end

  def self.opted_out_digests(category:, channel: 'email')
    where(category: category, channel: channel).select(:email_lookup_digest)
  end
end
