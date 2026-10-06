# One credential issued to a member by a CredentialProvider. The secret itself is never
# stored: it is shown once, in the response to the request that issued it, and only the
# first and last four characters of each secret field are kept (see Credentials::FieldHints)
# so the member can tell their credentials apart. Fields the provider marks non-secret, such
# as an OAuth client id, are kept whole.
#
# A `pending` row is written before the provider's program runs, so a crash between the
# program issuing and us recording it leaves a trace (and its request_id) rather than a
# credential nobody knows exists.
class Credential < ApplicationRecord
  STATUSES = %w[pending active paused expired revoked revoke_failed failed].freeze

  # Exist in the external system, so a member leaving must revoke them.
  LIVE_STATUSES = %w[active paused revoke_failed].freeze

  # Count against the provider's per-member limit.
  LIMIT_STATUSES = %w[pending active paused].freeze

  REVOCATION_REASONS = {
    'revoked_by_member' => 'Revoked by the member',
    'revoked_by_admin' => 'Revoked by an administrator',
    'member_inactive' => 'Membership no longer active',
    'key_access_paused' => 'Key access paused',
    'rotated' => 'Replaced by rotation',
    'issue_incomplete' => 'Issue did not complete'
  }.freeze

  # A pending row older than this never heard back from its program.
  PENDING_TIMEOUT = 10.minutes

  EXPIRY_WARNING = 7.days

  LABEL_LIMIT = 100

  UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # Credentials a script is still asked to revoke. An expired one is not live (it is not
  # revoked automatically) but may still be revoked by hand.
  REVOCABLE_STATUSES = (LIVE_STATUSES + %w[expired]).freeze

  belongs_to :credential_provider
  belongs_to :user
  belongs_to :issued_by, class_name: 'User', optional: true
  belongs_to :revoked_by, class_name: 'User', optional: true
  belongs_to :rotated_from, class_name: 'Credential', optional: true
  has_one :rotated_to, class_name: 'Credential', foreign_key: :rotated_from_id, inverse_of: :rotated_from,
                       dependent: :nullify
  has_many :credential_runs, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :request_id, presence: true, uniqueness: true
  validates :label, length: { maximum: LABEL_LIMIT }
  validates :revocation_reason, inclusion: { in: REVOCATION_REASONS.keys }, allow_nil: true

  before_validation { self.request_id ||= SecureRandom.uuid }

  scope :live, -> { where(status: LIVE_STATUSES) }
  scope :counting_toward_limit, -> { where(status: LIMIT_STATUSES) }
  scope :revoke_failed, -> { where(status: 'revoke_failed') }
  scope :stale_pending, -> { where(status: 'pending').where(created_at: ...PENDING_TIMEOUT.ago) }
  scope :expirable, -> { where(status: %w[active paused]).where.not(expires_at: nil) }
  scope :newest_first, -> { order(created_at: :desc) }

  STATUSES.each do |name|
    define_method(:"#{name}?") { status == name }
  end

  def live?
    LIVE_STATUSES.include?(status)
  end

  def revocable?
    REVOCABLE_STATUSES.include?(status) && external_id.present?
  end

  def rotatable?
    active? && credential_provider.available?
  end

  # What a member sees of each field: the whole value for a non-secret field, and the first
  # and last four characters of a secret one.
  def display_fields
    credential_provider.schema_fields.map do |field|
      { key: field['key'], label: field['label'], secret: field['secret'],
        display: Credentials::FieldHints.display(field_hints[field['key']]) }
    end
  end

  def display_name
    label.presence || credential_provider.schema_display_name
  end

  # How the credential is named in an email: the provider, then the member's own label.
  def notice_name
    [credential_provider.schema_display_name, label.presence].compact.join(' - ')
  end

  def revocation_reason_label
    REVOCATION_REASONS[revocation_reason]
  end

  def expiring_soon?(now = Time.current)
    expires_at.present? && expires_at > now && expires_at <= now + EXPIRY_WARNING
  end

  def status_label
    status == 'revoke_failed' ? 'Revocation failed' : status.humanize
  end

  def status_dot_class
    case status
    when 'active' then 'success'
    when 'paused', 'pending' then 'warning'
    when 'revoke_failed', 'failed' then 'danger'
    else 'muted'
    end
  end

  def journal!(action, actor: nil, extra: {})
    Journal.create!(
      user: user,
      actor_user: actor,
      action: action,
      changes_json: { 'credential' => journal_payload.merge(extra.stringify_keys) },
      changed_at: Time.current,
      highlight: %w[credential_issued credential_revoked credential_issue_incomplete].include?(action)
    )
  end

  private

  def journal_payload
    { 'id' => id, 'provider' => credential_provider.name, 'label' => label.to_s,
      'expires_at' => expires_at&.strftime('%B %d, %Y') }.compact
  end
end
