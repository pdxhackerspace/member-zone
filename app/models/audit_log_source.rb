# An external program that emits audit log lines. It is run on a schedule by
# AuditLogs::RunSourceJob and its output is stored, append-only, as AuditLogEntry rows.
#
# Modelled on AccessController/AccessControllerType: the program is a path the administrator
# types (by convention inside the audit-log/ subdirectory beside the access controller
# scripts), arguments are split on whitespace, and environment variables are encrypted.
class AuditLogSource < ApplicationRecord
  include SensitiveFields
  include ParsedEnvironmentVariables

  encrypts_sensitive_string :environment_variables

  INTERVALS = {
    'hourly' => 1.hour,
    'every_6_hours' => 6.hours,
    'every_12_hours' => 12.hours,
    'daily' => 1.day
  }.freeze

  INTERVAL_LABELS = {
    'hourly' => 'Hourly',
    'every_6_hours' => 'Every 6 hours',
    'every_12_hours' => 'Every 12 hours',
    'daily' => 'Daily'
  }.freeze

  RUN_STATUSES = %w[unknown running success failed].freeze

  # The dispatcher wakes hourly, a little after the hour, so a source whose interval is a
  # whole number of hours has always come round by the next wake-up.
  DUE_SLACK = 5.minutes

  # A run that never reported back (a killed worker) stops blocking the source after this long.
  STALE_RUN_AFTER = 1.hour

  belongs_to :training_topic, optional: true
  has_many :audit_log_entries, dependent: :restrict_with_error
  has_many :audit_log_runs, dependent: :destroy
  has_many :audit_log_alert_rules, dependent: :destroy

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :script_path, presence: true
  validates :run_interval, inclusion: { in: INTERVALS.keys }
  validates :run_status, inclusion: { in: RUN_STATUSES }

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(:name) }

  # Sources a member may read: every source with audit_logs.view_all, otherwise the ones
  # attached to a topic they hold audit_logs.view for (subtopics included).
  def self.readable_by(user)
    return none if user.nil?
    return all if user.can?(:'audit_logs.view_all')

    where(training_topic_id: user.topics_with_privilege(:'audit_logs.view').select(:id))
  end

  def readable_by?(user)
    return false if user.nil?
    return true if user.can?(:'audit_logs.view_all')

    training_topic.present? && user.can?(:'audit_logs.view', topic: training_topic)
  end

  def interval_label
    INTERVAL_LABELS.fetch(run_interval)
  end

  def interval_duration
    INTERVALS.fetch(run_interval)
  end

  def running?
    run_status == 'running' && last_run_at.present? && last_run_at > STALE_RUN_AFTER.ago
  end

  def due?(now = Time.current)
    return false unless enabled? && !running?

    last_run_at.nil? || last_run_at <= now - interval_duration + DUE_SLACK
  end

  # Marks the source as running unless another worker already holds it. Returns whether this
  # caller won.
  def claim_run!
    claimed = self.class.where(id: id)
                  .where("run_status <> 'running' OR last_run_at IS NULL OR last_run_at < ?", STALE_RUN_AFTER.ago)
                  .update_all(run_status: 'running', last_run_at: Time.current)
    reload if claimed == 1
    claimed == 1
  end

  # The command line as it will be run, for the run log.
  def command_arguments
    [script_path.to_s.strip, *script_arguments.to_s.split(/\s+/).compact_blank]
  end

  def status_label
    run_status.humanize
  end

  def status_badge_class
    case run_status
    when 'success' then 'success'
    when 'failed' then 'danger'
    when 'running' then 'info'
    else 'secondary'
    end
  end
end
