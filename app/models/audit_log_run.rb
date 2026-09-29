# One execution of an audit log source: what was run, what it printed, and how it ended.
class AuditLogRun < ApplicationRecord
  STATUSES = %w[running success failed].freeze

  belongs_to :audit_log_source

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
end
