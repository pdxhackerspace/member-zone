# A program that tells people a member has arrived (a Slack post, an entry sign greeting, ...).
# Members opt in to each one from their profile; Announcers::ArrivalDispatcher runs the ones a
# member chose when the access webhook reports them coming in through an outside door.
#
# Modelled on AuditLogSource: the program must live in the announcers/ subdirectory beside the
# access controller scripts, arguments are split on whitespace, and environment variables (which
# hold the secrets, such as a Slack bot token) are encrypted.
class Announcer < ApplicationRecord
  include SensitiveFields
  include ParsedEnvironmentVariables

  encrypts_sensitive_string :environment_variables

  RUN_STATUSES = %w[unknown success failed].freeze

  has_many :announcer_subscriptions, dependent: :destroy
  has_many :subscribers, through: :announcer_subscriptions, source: :user
  has_many :announcer_runs, dependent: :delete_all

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :script_path, presence: true
  validates :repeat_after_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :last_run_status, inclusion: { in: RUN_STATUSES }
  validate :script_path_in_catalog, if: :will_save_change_to_script_path?

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(:display_order, :name) }

  def command_arguments
    [script_path, 'announce', *script_arguments.to_s.split(/\s+/).compact_blank]
  end

  def repeat_after
    repeat_after_minutes.minutes
  end

  # Whether the member was announced by this announcer recently enough that announcing them again
  # would be spam. Failed runs don't count, so a broken script doesn't swallow the next arrival.
  def announced_recently?(user, now: Time.current)
    return false if repeat_after_minutes.zero?

    announcer_runs.where(user: user, test_run: false, status: %w[queued running success])
                  .exists?(['created_at > ?', now - repeat_after])
  end

  def record_run_result!(status)
    update_columns(last_run_status: status, last_run_at: Time.current, updated_at: Time.current)
  end

  private

  def script_path_in_catalog
    return if script_path.blank?
    return if Announcers::ScriptCatalog.allowed?(script_path)

    errors.add(:script_path, 'must be an executable file in an announcers script directory')
  end
end
