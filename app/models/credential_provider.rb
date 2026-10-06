# An external system that issues credentials to members — API keys, app passwords, OAuth
# clients — through a program in one of the credential script directories. The program is
# asked what it returns (`describe`), how it is (`health`), and to `issue`, `revoke`, and
# optionally `pause` and `resume` credentials; see docs/credentials.md for the protocol.
#
# Modelled on AuditLogSource and AccessControllerType: arguments are split on whitespace and
# environment variables (the provider's API keys) are encrypted at rest. Unlike those, the
# program must be one found in Credentials::ScriptCatalog, so editing a provider cannot be
# turned into running an arbitrary binary.
class CredentialProvider < ApplicationRecord
  include SensitiveFields
  include ParsedEnvironmentVariables
  include CredentialProviderSchema

  encrypts_sensitive_string :environment_variables

  HEALTH_STATUSES = %w[unknown healthy unhealthy not_configured].freeze
  UNAVAILABLE_HEALTH_STATUSES = %w[unhealthy not_configured].freeze

  has_many :credential_provider_training_topics, dependent: :destroy
  has_many :required_training_topics, through: :credential_provider_training_topics, source: :training_topic
  has_many :credentials, dependent: :restrict_with_error
  has_many :credential_runs, dependent: :destroy

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :script_path, presence: true
  validates :health_status, inclusion: { in: HEALTH_STATUSES }
  validates :max_per_member, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100 }
  # Only when the path is being set: a program that has since left the catalog must not stop
  # the provider being disabled or edited. Credentials::Invocation refuses to run it instead.
  validate :script_path_in_catalog, if: :will_save_change_to_script_path?

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(:name) }
  scope :self_service, -> { where(self_service: true) }

  # Enabled providers a broken health check or missing schema has taken out of service.
  def self.needing_attention
    enabled.where(health_status: UNAVAILABLE_HEALTH_STATUSES)
  end

  # Unhealthy providers plus credentials whose revocation keeps failing or whose issue never
  # finished — each is something an administrator has to look at.
  def self.attention_count
    needing_attention.count + Credential.revoke_failed.count + Credential.stale_pending.count
  end

  # Script path then action then the configured arguments, as it is run.
  def command_arguments(action)
    [script_path.to_s.strip, action.to_s, *script_arguments.to_s.split(/\s+/).compact_blank]
  end

  def available?
    enabled? && schema_ready? && UNAVAILABLE_HEALTH_STATUSES.exclude?(health_status)
  end

  # Why +user+ cannot be issued a credential from this provider by anyone, or nil when they
  # can. Self-service adds one more condition; see #self_service_denial_reason.
  # +replacing+ is a credential about to be rotated; it does not count against the limit.
  def issue_denial_reason(user, replacing: nil)
    return 'This provider is disabled.' unless enabled?
    return 'This provider has not reported what it issues yet.' unless schema_ready?
    return 'This provider is currently unavailable.' if UNAVAILABLE_HEALTH_STATUSES.include?(health_status)

    member_denial_reason(user, replacing)
  end

  def self_service_denial_reason(user, replacing: nil)
    return 'Credentials from this provider are issued by an administrator.' unless self_service?

    issue_denial_reason(user, replacing: replacing)
  end

  def missing_training_topics(user)
    required = required_training_topics.to_a
    return [] if required.empty?

    held = user.trainings_as_trainee.distinct.pluck(:training_topic_id)
    required.reject { |topic| held.include?(topic.id) }
  end

  def record_health!(status, message)
    attrs = { health_status: status, health_message: message.to_s.truncate(1000).presence,
              last_health_check_at: Time.current }
    attrs[:last_healthy_at] = Time.current if status == 'healthy'
    update_columns(attrs.merge(updated_at: Time.current))
  end

  def health_label
    health_status.humanize
  end

  def health_dot_class
    case health_status
    when 'healthy' then 'success'
    when 'unhealthy', 'not_configured' then 'danger'
    else 'muted'
    end
  end

  private

  def member_denial_reason(user, replacing = nil)
    return 'Only active members can be issued credentials.' unless user&.active?
    return 'Credentials cannot be issued while key access is paused.' if user.key_access_paused?

    missing = missing_training_topics(user)
    return "Requires training in #{missing.map(&:name).to_sentence}." if missing.any?

    held = credentials.where(user: user).counting_toward_limit.where.not(id: replacing&.id).count
    return "Limit of #{max_per_member} reached. Revoke one first." if held >= max_per_member

    nil
  end

  def script_path_in_catalog
    return if script_path.blank?
    return if Credentials::ScriptCatalog.allowed?(script_path)

    errors.add(:script_path, 'must be an executable file in a credential script directory')
  end
end
