# A regular expression that, when it matches a new entry from its source, alerts the people
# responsible for that source by email.
class AuditLogAlertRule < ApplicationRecord
  # A pattern that backtracks catastrophically must not be able to stall the job that
  # checks it, so every match runs against this budget.
  MATCH_TIMEOUT = 1.0

  belongs_to :audit_log_source

  validates :name, presence: true
  validates :pattern, presence: true
  validate :pattern_compiles

  scope :enabled, -> { where(enabled: true) }

  def regexp
    @regexp ||= Regexp.new(pattern, case_insensitive? ? Regexp::IGNORECASE : 0, timeout: MATCH_TIMEOUT)
  end

  # Timeouts count as a non-match: an alert that cannot be evaluated must not break ingest.
  def matches?(text)
    regexp.match?(text.to_s)
  rescue Regexp::TimeoutError
    Rails.logger.warn("[AuditLogs] alert rule #{id} timed out and was skipped")
    false
  end

  def pattern=(value)
    @regexp = nil
    super
  end

  private

  def pattern_compiles
    return if pattern.blank?

    Regexp.new(pattern)
  rescue RegexpError => e
    errors.add(:pattern, "is not a valid regular expression (#{e.message})")
  end
end
