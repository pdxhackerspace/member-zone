# A bearer token for the Member Zone API. See docs/api-plan.md and docs/api.md.
#
# Every token belongs to a holder: a member (a personal token) or a service account (a device or
# integration, which outlives whoever set it up). What a token may do is its scopes — privilege
# keys — intersected with what its holder may do at the moment of the request, so a holder who
# loses a role loses it on every token at once, and no token ever does more than its scopes say.
#
# Only a SHA-256 digest of the secret is stored. The plaintext is available once, on the instance
# that generated it, and never again. Extending a token keeps its secret, so a client that let a
# token lapse needs nothing more than an extension to start working again.
class ApiToken < ApplicationRecord
  PREFIX = 'mz_'.freeze
  TOKEN_BYTES = 32
  # last_used_at is a hint for humans, not an audit trail; writing it on every request would turn
  # each read into a write.
  USE_RECORDING_INTERVAL = 1.minute
  STATES = %w[active suspended expired revoked].freeze
  # Privileges every active member holds by being a member, with no role needed: what a member
  # can do for themselves on the website. They are in the privilege catalog so a token can name
  # them as scopes; roles never need to confer them.
  MEMBERSHIP_SCOPES = %w[parking.own_permits].freeze

  belongs_to :user
  belongs_to :contact_user, class_name: 'User', optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :suspended_by, class_name: 'User', optional: true
  belongs_to :revoked_by, class_name: 'User', optional: true

  # Who is setting the scopes, when that is not the creator. Only used by validation.
  attr_accessor :scopes_set_by

  # The plaintext token, available only on the instance that generated it.
  attr_reader :token

  validates :name, presence: true, length: { maximum: 100 }
  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validates :created_by, presence: true, on: :create
  validate :scopes_are_grantable, if: :will_save_change_to_scopes?
  validate :expiry_within_max_lifetime, if: :will_save_change_to_expires_at?

  before_validation :normalize_scopes
  before_validation :issue_token, on: :create
  before_validation :default_contact, on: :create
  before_validation :default_expiry, on: :create

  scope :revoked, -> { where.not(revoked_at: nil) }
  scope :not_revoked, -> { where(revoked_at: nil) }
  scope :suspended, -> { not_revoked.where.not(suspended_at: nil) }
  scope :expired, ->(now = Time.current) { not_revoked.where(expires_at: ..now) }
  scope :usable, ->(now = Time.current) { not_revoked.where(suspended_at: nil).where(expires_at: now..) }
  scope :personal, -> { joins(:user).where(users: { service_account: false }) }
  scope :service, -> { joins(:user).where(users: { service_account: true }) }
  scope :newest_first, -> { order(created_at: :desc) }

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token.to_s)
  end

  def self.max_lifetime
    DefaultSetting.instance.api_token_max_lifetime_days.days
  end

  # The token +raw+ names, if it may be used right now; otherwise nil. Lookup is by digest, so
  # the comparison happens in the database index rather than in Ruby and leaks nothing about
  # near-misses. Callers that need to know why a token was refused use #rejection_reason.
  def self.authenticate(raw, now: Time.current)
    token = lookup(raw)
    token if token&.usable?(now: now)
  end

  def self.lookup(raw)
    return nil if raw.blank?

    includes(:user).find_by(token_digest: digest(raw))
  end

  def rejection_reason(now: Time.current)
    return :revoked if revoked?
    return :suspended if suspended?
    return :expired if expired?(now: now)

    :holder_inactive unless user.active?
  end

  def usable?(now: Time.current)
    rejection_reason(now: now).nil?
  end

  def revoked?
    revoked_at.present?
  end

  def suspended?
    suspended_at.present?
  end

  def expired?(now: Time.current)
    expires_at <= now
  end

  def service?
    user.service_account?
  end

  def personal?
    !service?
  end

  # Revoked wins over suspended, which wins over expired: the state is what someone has to undo.
  def state(now: Time.current)
    return 'revoked' if revoked?
    return 'suspended' if suspended?
    return 'expired' if expired?(now: now)

    'active'
  end

  def expiring_soon?(window, now: Time.current)
    !revoked? && expires_at > now && expires_at <= now + window
  end

  # Does this token let its holder use +key+ right now? The scope has to be on the token, and the
  # holder has to have the privilege. An administrator's token is still limited to its scopes.
  def allows?(key)
    key = key.to_s
    scopes.include?(key) && self.class.holder_has?(user, key)
  end

  def self.membership_scope?(key)
    MEMBERSHIP_SCOPES.include?(key.to_s)
  end

  def self.holder_has?(user, key)
    return user.active? && !user.service_account? if membership_scope?(key)

    user.can?(key)
  end

  # Pushes the expiry out by the maximum lifetime from now. Works on an expired token too, and
  # keeps the secret, so the client using it needs no change.
  def extend!(by:, now: Time.current)
    raise ActiveRecord::RecordInvalid, invalid_because(:base, 'A revoked token cannot be extended') if revoked?

    update!(expires_at: now + self.class.max_lifetime, last_extended_at: now)
    journal!('api_token_extended', actor: by)
  end

  def suspend!(by:, reason: nil, now: Time.current)
    raise ActiveRecord::RecordInvalid, invalid_because(:base, 'A revoked token cannot be suspended') if revoked?

    update!(suspended_at: now, suspended_by: by, suspended_reason: reason.presence)
    journal!('api_token_suspended', actor: by)
  end

  def resume!(by:)
    raise ActiveRecord::RecordInvalid, invalid_because(:base, 'A revoked token cannot be resumed') if revoked?

    update!(suspended_at: nil, suspended_by: nil, suspended_reason: nil)
    journal!('api_token_resumed', actor: by)
  end

  # Permanent. A revoked token can never be used, extended, or brought back.
  def revoke!(by:, reason: nil, now: Time.current)
    return if revoked?

    update!(revoked_at: now, revoked_by: by, revoked_reason: reason.presence)
    journal!('api_token_revoked', actor: by)
  end

  def record_use!(ip:, now: Time.current)
    return if last_used_at.present? && last_used_at > now - USE_RECORDING_INTERVAL

    update_columns(last_used_at: now, last_used_ip: ip.to_s.first(64), updated_at: now)
  end

  def journal!(action, actor: nil)
    Journal.create!(
      user: user,
      actor_user: actor,
      action: action,
      changes_json: { 'api_token' => { 'id' => id, 'name' => name, 'hint' => token_hint,
                                       'expires_at' => expires_at.strftime('%B %d, %Y') } },
      changed_at: Time.current,
      highlight: %w[api_token_created api_token_revoked].include?(action)
    )
  end

  private

  def issue_token
    return if token_digest.present?

    @token = "#{PREFIX}#{SecureRandom.urlsafe_base64(TOKEN_BYTES)}"
    self.token_digest = self.class.digest(@token)
    self.token_hint = @token.last(4)
  end

  def default_contact
    self.contact_user ||= created_by
  end

  def default_expiry
    self.expires_at ||= Time.current + self.class.max_lifetime
  end

  def normalize_scopes
    self.scopes = Array(scopes).map { |scope| scope.to_s.strip }.compact_blank.uniq.sort
  end

  # A scope must be a global privilege in the catalog that the holder has, and that whoever is
  # granting it has too — nobody hands out authority they do not hold.
  def scopes_are_grantable
    granter = scopes_set_by || created_by
    scopes.each do |key|
      entry = Privilege.catalog_entry(key)
      next errors.add(:scopes, "#{key} is not a privilege") if entry.nil?
      next errors.add(:scopes, "#{key} only applies within a training topic") if entry[:privilege_scope] == 'topic'
      if user && !self.class.holder_has?(user, key)
        next errors.add(:scopes, "#{key} is not held by #{user.display_name}")
      end

      errors.add(:scopes, "#{key} is not yours to grant") if granter && !granter_has?(granter, key)
    end
  end

  # Membership privileges come with being an active member rather than with a role, so roles
  # cannot answer for them.
  def granter_has?(granter, key)
    return true if granter.is_admin?
    return granter.active? if self.class.membership_scope?(key)

    granter.can?(key)
  end

  def expiry_within_max_lifetime
    return if expires_at.blank?
    return if expires_at <= Time.current + self.class.max_lifetime + 1.minute

    errors.add(:expires_at, "must be within #{DefaultSetting.instance.api_token_max_lifetime_days} days")
  end

  def invalid_because(attribute, message)
    errors.add(attribute, message)
    self
  end
end
