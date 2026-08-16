class User < ApplicationRecord
  include SensitiveFields
  include MembershipState
  include BuildingAccessTraining

  encrypts_sensitive_string :email, :mailing_address, :phone_number
  encrypts_sensitive_string_array :extra_emails
  has_email_lookup :email, digest_column: :email_lookup_digest

  belongs_to :membership_plan, optional: true # Primary plan
  has_many :user_supplementary_plans, dependent: :destroy
  has_many :supplementary_plans, through: :user_supplementary_plans, source: :membership_plan
  has_one :sheet_entry, dependent: :nullify
  has_one :slack_user, dependent: :nullify
  has_one :authentik_user, dependent: :nullify
  has_many :personal_membership_plans, class_name: 'MembershipPlan', dependent: :destroy
  has_many :paypal_payments, dependent: :nullify
  has_many :recharge_payments, dependent: :nullify
  has_many :cash_payments, dependent: :destroy
  has_many :payment_events, dependent: :destroy
  has_many :journals, dependent: :destroy
  has_many :access_logs, dependent: :nullify
  has_many :rfids, dependent: :destroy
  has_many :trainer_capabilities, dependent: :destroy
  has_many :training_topics, through: :trainer_capabilities
  has_many :training_requests, dependent: :destroy
  has_many :training_requests_responded, class_name: 'TrainingRequest', foreign_key: :responded_by_id,
                                         dependent: :nullify, inverse_of: :responded_by
  has_many :user_links,     dependent: :destroy
  has_many :user_interests, dependent: :destroy
  has_many :interests,      through: :user_interests
  has_many :trainings_as_trainee, class_name: 'Training', foreign_key: 'trainee_id', dependent: :destroy
  has_many :trainings_as_trainer, class_name: 'Training', foreign_key: 'trainer_id', dependent: :destroy
  has_and_belongs_to_many :application_groups
  has_many :queued_mails, foreign_key: 'recipient_id', dependent: :nullify
  has_many :reported_incidents, class_name: 'IncidentReport', foreign_key: 'reporter_id', dependent: :nullify
  has_and_belongs_to_many :incident_reports, join_table: 'incident_report_members'
  has_many :parking_notices, dependent: :nullify
  has_many :membership_applications, -> { newest_first }, dependent: :nullify, inverse_of: :user
  has_many :invitations, dependent: :nullify
  has_many :sent_invitations, class_name: 'Invitation', foreign_key: 'invited_by_id', dependent: :nullify
  has_many :sent_messages, class_name: 'Message', foreign_key: 'sender_id', dependent: :destroy
  has_many :received_messages, class_name: 'Message', foreign_key: 'recipient_id', dependent: :destroy
  validates :authentik_id, uniqueness: true, allow_blank: true
  validates :username, uniqueness: true, allow_blank: true
  validates :email,
            allow_blank: true,
            format: {
              with: URI::MailTo::EMAIL_REGEXP,
              allow_blank: true
            }
  validates :email_lookup_digest, uniqueness: true, allow_blank: true
  validates :payment_type, inclusion: { in: %w[unknown sponsored paypal recharge kofi cash inactive] }

  PROFILE_VISIBILITY_OPTIONS = %w[public members private].freeze

  # The settings by which a member has opted into being shown to other members. 'private'
  # is the absent one: those profiles are for their owner and for the roles entitled to
  # read any profile.
  SHARED_PROFILE_VISIBILITIES = %w[public members].freeze

  # Lookup digests are derived from email and carry no meaning in a member's history.
  JOURNAL_DERIVED_ATTRIBUTES = %w[email_lookup_digest extra_email_lookup_digests].freeze
  validates :profile_visibility, inclusion: { in: PROFILE_VISIBILITY_OPTIONS }
  validates :dues_status, inclusion: { in: %w[current lapsed inactive unknown] }
  validates :mailing_latitude,
            numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 },
            allow_nil: true
  validates :mailing_longitude,
            numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 },
            allow_nil: true
  validate :extra_emails_format
  validate :email_is_unique

  # Submitted with admin user form: if set for guest/sponsored, sets dues_due_at to now + N months
  attr_accessor :sponsored_guest_duration_months

  # Virtual attribute for comma-separated alias editing
  def aliases_text
    (aliases || []).join(', ')
  end

  def aliases_text=(value)
    self.aliases = value.to_s.split(',').map(&:strip).compact_blank.uniq
  end

  def self.lookup_by_email(email)
    by_email(email).first
  end

  def self.by_email(email)
    digest = SensitiveData.email_digest(email)
    normalized = SensitiveData.normalize_email(email)
    return none if digest.blank?

    where(email_lookup_digest: digest).or(where('LOWER(email) = ?', normalized))
  end

  def self.by_any_email(email)
    digest = SensitiveData.email_digest(email)
    normalized = SensitiveData.normalize_email(email)
    return none if digest.blank?

    where(email_lookup_digest: digest)
      .or(where('? = ANY(extra_email_lookup_digests)', digest))
      .or(where('LOWER(email) = ?', normalized))
      .or(where('EXISTS (SELECT 1 FROM unnest(extra_emails) AS email WHERE LOWER(email) = ?)', normalized))
  end

  def set_extra_email_lookup_digests
    return unless has_attribute?(:extra_email_lookup_digests)

    self.extra_email_lookup_digests = SensitiveData.email_digests(extra_emails)
  end

  def email_is_unique
    return if email.blank?

    relation = self.class.by_email(email)
    relation = relation.where.not(id: id) if persisted?
    errors.add(:email, :taken) if relation.exists?
  end

  # Find a user whose full_name or any alias exactly matches the given name (case-insensitive).
  # No prefix or partial matching — the whole stored name must equal the query string.
  scope :by_name_or_alias, lambda { |name|
    normalized = name.to_s.strip.downcase
    where(
      'LOWER(full_name) = :name OR EXISTS ' \
      '(SELECT 1 FROM unnest(aliases) AS a WHERE LOWER(a) = :name)',
      name: normalized
    )
  }

  # The members a viewer who is not entitled to read every profile may be shown: the ones
  # who opted into sharing, plus the viewer themselves, who is always allowed to find their
  # own name. `where(id: nil)` for a missing viewer matches nobody.
  scope :profile_visible_to, lambda { |viewer|
    where(profile_visibility: SHARED_PROFILE_VISIBILITIES).or(where(id: viewer))
  }

  scope :active, -> { where(active: true) }
  scope :key_access_paused, -> { where(key_access_paused: true) }
  scope :key_access_active, -> { where(key_access_paused: false) }
  scope :admin, -> { where(is_admin: true) }
  scope :service_accounts, -> { where(service_account: true) }
  scope :non_service_accounts, -> { where(service_account: false) }
  scope :legacy, -> { where(legacy: true) }
  scope :non_legacy, -> { where(legacy: false) }
  scope :is_sponsored, -> { where(is_sponsored: true) }
  scope :authentik_dirty, -> { where(authentik_dirty: true) }
  scope :with_attribute, ->(key, value) { where('authentik_attributes ->> ? = ?', key.to_s, value.to_s) }
  scope :ordered_by_display_name, lambda {
    order(
      Arel.sql("LOWER(COALESCE(NULLIF(full_name, ''), NULLIF(username, ''), authentik_id)) ASC"),
      :username,
      :authentik_id
    )
  }

  def display_name
    full_name.presence || email.presence || authentik_id
  end

  def membership_approved_at
    membership_applications.approved.maximum(:reviewed_at) || created_at
  end

  # Add a name as an alias if it differs from full_name and isn't already present.
  # Returns true if the alias was added, false otherwise.
  def add_alias(name)
    return false if name.blank?

    normalized = name.to_s.strip
    return false if normalized.blank?
    return false if full_name.present? && full_name.strip.downcase == normalized.downcase
    return false if (aliases || []).any? { |a| a.strip.downcase == normalized.downcase }

    self.aliases = (aliases || []) + [normalized]
    true
  end

  # Add alias and save immediately.
  def add_alias!(name)
    add_alias(name) && save!
  end

  # Pause this member's RFID key access without removing or deactivating their keys.
  # Paused members are excluded from access controller syncs (see AccessControllerPayloadBuilder).
  def pause_key_access!
    return false if key_access_paused?

    update!(key_access_paused: true, key_access_paused_at: Time.current)
  end

  def resume_key_access!
    return false unless key_access_paused?

    update!(key_access_paused: false, key_access_paused_at: nil)
  end

  def username
    self[:username].presence || (authentik_attributes || {})['username'].presence || authentik_id
  end

  # Username (and optional @slack handle) for parking permits/tickets — avoids exposing legal names or email.
  def parking_member_label
    handle = slack_handle.presence || slack_user&.username
    handle.present? ? "#{username} @#{handle}" : username.to_s
  end

  def admin?
    is_admin?
  end

  # Does this member hold a privilege? Admins always do: is_admin is a permanent
  # superuser bypass so misconfigured roles can never lock administrators out.
  #
  # Global privileges apply once any held topic confers them. Topic-scoped privileges
  # apply only for the topic that conferred them, so callers must pass that topic.
  def can?(privilege_key, topic: nil)
    return true if is_admin?

    key = privilege_key.to_s
    return true if global_privilege_keys.include?(key)
    return false if topic.nil?

    topic_scoped_privilege_keys(topic).include?(key)
  end

  def global_privilege_keys
    @global_privilege_keys ||=
      conferred_privileges.filter_map { |_topic_id, privilege| privilege.key if privilege.global? }.uniq
  end

  # Topic-scoped privileges apply for the topic that conferred them and for that topic's
  # direct children: taking on a topic makes you responsible for the subtopics nested under
  # it. Reach stops after one level, so a privilege never cascades down a whole tree.
  def topic_scoped_privilege_keys(topic)
    conferring_ids = privilege_conferring_topic_ids(topic)

    conferred_privileges.filter_map do |conferring_topic_id, privilege|
      privilege.key if privilege.topic_scoped? && conferring_ids.include?(conferring_topic_id)
    end.uniq
  end

  # Does this member hold a privilege for at least one topic? Use for entry points such as
  # navigation, where the specific topic is not known yet.
  def can_for_any_topic?(privilege_key)
    return true if is_admin?

    key = privilege_key.to_s
    return true if global_privilege_keys.include?(key)

    conferred_privileges.any? { |_topic_id, privilege| privilege.key == key }
  end

  # Topics for which this member holds a topic-scoped privilege, including the direct
  # subtopics those privileges reach into.
  def topics_with_privilege(privilege_key)
    return TrainingTopic.all if is_admin?

    key = privilege_key.to_s
    topic_ids = conferred_privileges.filter_map { |topic_id, privilege| topic_id if privilege.key == key }.uniq

    TrainingTopic.where(id: topic_ids).or(TrainingTopic.where(parent_id: topic_ids))
  end

  # No-escalation rule: conferring a topic hands over its privileges, so the actor must
  # already hold everything it would grant. Containment covers global privileges only —
  # requiring it for topic-scoped ones would stop a director from appointing a trainer
  # for equipment they do not curate themselves.
  def may_confer?(topic, member_sources:)
    return true if is_admin?

    topic.conferred_global_privilege_keys(member_sources: member_sources).all? { |key| can?(key) }
  end

  # Renaming or deleting a topic on the strength of a parent's role. Unlike the usual
  # one-level reach in can?, this deliberately never matches the topic that conferred it: a
  # role attached to a parent hands out authority over its subtopics, not over itself.
  def may_manage_subtopic?(topic)
    return true if can?(:'training.topics.manage')

    parent_id = topic.is_a?(TrainingTopic) ? topic.parent_id : TrainingTopic.where(id: topic.to_i).pick(:parent_id)
    return false if parent_id.nil?

    conferred_privileges.any? do |conferring_topic_id, privilege|
      conferring_topic_id == parent_id && privilege.key == 'training.subtopics.manage'
    end
  end

  # Appointing or removing a trainer confers the topic's can_train roles, and the Training
  # record created alongside confers its trained_in roles, so containment covers both.
  def may_manage_trainer_capability?(topic)
    return false unless can?(:'training.grant_trainer')

    may_confer?(topic, member_sources: TrainingTopicRole::MEMBER_SOURCES)
  end

  # Recording or revoking training for a topic, subject to the no-escalation rule.
  def may_record_training?(topic)
    return false unless training_topics.include?(topic) || can?(:'training.record', topic: topic)

    may_confer?(topic, member_sources: %w[trained_in])
  end

  def may_revoke_training?(topic)
    return false unless can?(:'training.revoke', topic: topic)

    may_confer?(topic, member_sources: %w[trained_in])
  end

  # Privileges conferred by every topic this member holds, as [topic_id, privilege] pairs.
  # Cached per instance; call reset_privilege_cache! after changing the member's training.
  def conferred_privileges
    @conferred_privileges ||= build_conferred_privileges
  end

  def reset_privilege_cache!
    @conferred_privileges = nil
    @global_privilege_keys = nil
  end

  # Members conferred a privilege through a role, ignoring the is_admin bypass.
  # Used for notification routing, where admin status says nothing about job function.
  def self.with_privilege(privilege_key)
    attachments = TrainingTopicRole.joins(role: :privileges).where(privileges: { key: privilege_key.to_s })
    trained = Training.where(training_topic_id: attachments.trained_in.select(:training_topic_id))
                      .select(:trainee_id)
    trainers = TrainerCapability.where(training_topic_id: attachments.can_train.select(:training_topic_id))
                                .select(:user_id)

    where(id: trained).or(where(id: trainers))
  end

  # Get training topics with links that the user is trained in
  # Returns topics ordered alphabetically by name, only those with at least one link
  def training_topics_with_links
    trained_topic_ids = trainings_as_trainee.pluck(:training_topic_id).uniq
    return [] if trained_topic_ids.empty?

    TrainingTopic.where(id: trained_topic_ids)
                 .joins(:links)
                 .distinct
                 .includes(:links)
                 .order(:name)
  end

  # Get documents available to this user based on their training or show_on_all_profiles flag
  # Returns deduplicated list ordered alphabetically by title
  def available_documents
    # Get all training topic IDs the user is trained in
    trained_topic_ids = trainings_as_trainee.pluck(:training_topic_id).uniq

    # Get documents shown to all profiles OR associated with trained topics
    if trained_topic_ids.empty?
      Document.where(show_on_all_profiles: true).ordered
    else
      Document.left_joins(:document_training_topics)
              .where(
                'documents.show_on_all_profiles = ? OR document_training_topics.training_topic_id IN (?)',
                true,
                trained_topic_ids
              )
              .distinct
              .ordered
    end
  end

  # Get the most recent payment date across all payment sources
  def most_recent_payment_date
    dates = []
    dates << last_payment_date if last_payment_date.present?
    dates << recharge_most_recent_payment_date.to_date if recharge_most_recent_payment_date.present?

    latest_paypal = paypal_payments.maximum(:transaction_time)
    latest_recharge = recharge_payments.maximum(:processed_at)
    latest_cash = cash_payments.maximum(:paid_on)
    dates << latest_paypal.to_date if latest_paypal.present?
    dates << latest_recharge.to_date if latest_recharge.present?
    dates << latest_cash if latest_cash.present?

    dates.compact.max
  end

  # Next billing-cycle boundary (paying) or end of limited guest/sponsored access, persisted on `dues_due_at`.
  def next_payment_date
    dues_due_at&.to_date
  end

  # When the next payment is due after a payment on anchor_date, given the plan's billing frequency.
  def self.dues_due_at_from_payment_cycle(anchor_date, plan)
    return nil if anchor_date.blank? || plan.blank?

    duration = plan.billing_cycle_duration
    return nil if duration.blank?

    d = anchor_date.to_date + duration
    d&.in_time_zone&.beginning_of_day
  end

  def limited_guest_or_sponsored_access_expired?
    dues_due_at.present? && dues_due_at < Time.current
  end

  # States a linked payment must not overwrite: each was set deliberately, and a payment
  # discovered by a sync is not evidence that the decision has been reversed.
  PAYMENT_IMMUNE_STATES = %w[cancelled_member banned_member deceased_member sponsored_member].freeze

  # How long after a payment the user is still considered current.
  # Based on the membership plan's billing cycle plus a small grace window.
  # Returns nil for one-time plans (payment never expires).
  # Falls back to MembershipSetting.planless_payment_window_days when no plan is assigned.
  def payment_currency_window(billing_plan: nil)
    plan = billing_plan || membership_plan
    cycle = plan&.billing_cycle_duration
    return cycle + MembershipSetting.payment_currency_buffer_days.days if cycle

    plan&.billing_frequency == 'one-time' ? nil : MembershipSetting.planless_payment_window_days.days
  end

  # Check if user is within the reactivation grace period
  def within_reactivation_grace_period?
    return false unless dues_status == 'lapsed'

    last_payment = most_recent_payment_date
    return false if last_payment.blank?

    grace_months = MembershipSetting.reactivation_grace_period_months
    cutoff_date = grace_months.months.ago.to_date
    last_payment >= cutoff_date
  end

  # Calculate when the reactivation grace period expires
  def reactivation_expires_on
    return nil unless dues_status == 'lapsed'

    last_payment = most_recent_payment_date
    return nil if last_payment.blank?

    grace_months = MembershipSetting.reactivation_grace_period_months
    last_payment + grace_months.months
  end

  # Check if user is lapsed and past the grace period (needs re-orientation)
  def past_reactivation_grace_period?
    return false unless dues_status == 'lapsed'

    last_payment = most_recent_payment_date
    # If no payment history, they're past the grace period
    return true if last_payment.blank?

    grace_months = MembershipSetting.reactivation_grace_period_months
    cutoff_date = grace_months.months.ago.to_date
    last_payment < cutoff_date
  end

  # Use username in URLs instead of ID
  def to_param
    username.presence || id.to_s
  end

  def generate_login_token!
    expiry = if admin?
               MembershipSetting.admin_login_link_expiry_minutes.minutes.from_now
             else
               MembershipSetting.login_link_expiry_hours.hours.from_now
             end
    update!(
      login_token: SecureRandom.alphanumeric(64),
      login_token_expires_at: expiry
    )
  end

  def clear_login_token!
    update!(login_token: nil, login_token_expires_at: nil)
  end

  def login_token_expired?
    login_token_expires_at.present? && login_token_expires_at <= Time.current
  end

  def login_token_active?
    login_token.present? && !login_token_expired?
  end

  # Called when a PaypalPayment is linked to this User.
  # Handles payer ID, email syncing, payment type, membership status, and plan matching.
  # Also links all other PayPal payments with the same payer_id.
  def on_paypal_payment_linked(payment)
    return if payment.blank?

    updates = {}

    # Set paypal_account_id from the payment's payer_id
    updates[:paypal_account_id] = payment.payer_id if payment.payer_id.present? && paypal_account_id != payment.payer_id

    # Sync email from payment
    merge_email_from_external_source(payment.payer_email, updates)

    # Set payment_type to 'paypal'
    updates[:payment_type] = 'paypal' if payment_type != 'paypal'

    # Update payment dates, membership status, and try to match plan
    apply_payment_updates({ time: payment.transaction_time, amount: payment.amount }, updates)

    # Apply all updates at once
    update!(updates) if updates.any?

    # Link all other PayPal payments with the same payer_id to this user
    link_all_paypal_payments_by_payer_id(payment.payer_id)

    # Create payment events for all linked PayPal payments
    ensure_paypal_payment_events(payment.payer_id)
  end

  # Called when a RechargePayment is linked to this User.
  # Handles customer ID, email syncing, payment type, membership status, and plan matching.
  # Also links all other Recharge payments with the same customer_id.
  def on_recharge_payment_linked(payment)
    return if payment.blank?

    updates = {}

    # Set recharge_customer_id from the payment's customer_id
    if payment.customer_id.present? && recharge_customer_id != payment.customer_id.to_s
      updates[:recharge_customer_id] = payment.customer_id.to_s
    end

    # Sync email from payment
    merge_email_from_external_source(payment.customer_email, updates)

    # Set payment_type to 'recharge'
    updates[:payment_type] = 'recharge' if payment_type != 'recharge'

    # Update recharge_most_recent_payment_date
    if payment.processed_at.present?
      payment_date = payment.processed_at.to_date
      if recharge_most_recent_payment_date.nil? || payment_date > recharge_most_recent_payment_date.to_date
        updates[:recharge_most_recent_payment_date] = payment.processed_at
      end
    end

    # Update payment dates, membership status, and try to match plan
    apply_payment_updates({ time: payment.processed_at, amount: payment.amount }, updates)

    # Apply all updates at once
    update!(updates) if updates.any?

    # Link all other Recharge payments with the same customer_id to this user
    link_all_recharge_payments_by_customer_id(payment.customer_id)

    # Create payment events for all linked Recharge payments
    ensure_recharge_payment_events(payment.customer_id)
  end

  # Shared method to update user from a payment.
  # Used by payment linking callbacks and synchronizer reconciliation.
  # Updates last_payment_date, membership status, and membership plan if needed.
  # Can accept either a time or a hash with :time and :amount.
  # billing_plan: plan that governs this payment's cycle (e.g. a personal plan on a cash payment)
  def apply_payment_updates(payment_time_or_options, updates = {}, billing_plan: nil)
    return updates if payment_time_or_options.blank?

    # Support both simple time and options hash
    if payment_time_or_options.is_a?(Hash)
      payment_time = payment_time_or_options[:time]
      payment_amount = payment_time_or_options[:amount]
    else
      payment_time = payment_time_or_options
      payment_amount = nil
    end

    return updates if payment_time.blank?

    payment_date = payment_time.to_date

    # Update last_payment_date if this payment is more recent
    updates[:last_payment_date] = payment_date if last_payment_date.nil? || payment_date > last_payment_date

    # A payment inside the billing window makes them a current member. membership_status,
    # dues_status, and active are projections of that and are rewritten on save.
    window = payment_currency_window(billing_plan: billing_plan)
    payment_is_current = window.nil? || payment_date >= window.ago.to_date
    if payment_is_current
      # Don't override deliberate states — these are set by admin actions, webhooks, or
      # subscription sync and should not be reverted by a historical payment turning up
      # in a sync. A cancelled member's last payment is expected to still be recent.
      unless membership_state.in?(PAYMENT_IMMUNE_STATES) || current_member?
        updates[:membership_state] = 'current_member'
      end
      updates[:membership_ended_date] = nil if membership_ended_date.present?
    end

    maybe_match_plan_from_payment_amount!(updates, payment_amount)

    merge_dues_due_at_after_payment!(updates, payment_date, billing_plan: billing_plan)

    updates
  end

  def merge_dues_due_at_after_payment!(updates, payment_date, billing_plan: nil)
    state = updates[:membership_state] || membership_state
    return if state.in?(%w[guest_member sponsored_member banned_member deceased_member])

    anchor = [last_payment_date, payment_date, updates[:last_payment_date]].compact.max
    plan = billing_plan || MembershipPlan.find_by(id: updates[:membership_plan_id] || membership_plan_id)
    updates[:dues_due_at] = User.dues_due_at_from_payment_cycle(anchor, plan)
  end

  def maybe_match_plan_from_payment_amount!(updates, payment_amount)
    return unless membership_plan_id.blank? && payment_amount.present? && payment_amount.positive?

    matched_plan = find_matching_membership_plan(payment_amount)
    updates[:membership_plan_id] = matched_plan.id if matched_plan
  end

  # Find a membership plan that matches the given payment amount
  # Only matches primary plans for the primary plan slot
  def find_matching_membership_plan(amount)
    return nil if amount.blank? || amount <= 0

    plans = MembershipPlan.primary

    # Try exact match first
    exact_match = plans.find { |p| p.cost == amount }
    return exact_match if exact_match

    # Try matching within a small tolerance (for rounding differences)
    tolerance = 0.50
    close_match = plans.find { |p| (p.cost - amount).abs <= tolerance }
    return close_match if close_match

    nil
  end

  # Get all membership plans (primary + supplementary)
  def all_membership_plans
    plans = []
    plans << membership_plan if membership_plan.present?
    plans + supplementary_plans.order(:name).to_a
  end

  # Add a supplementary plan to this user (idempotent)
  def add_supplementary_plan(plan)
    return false unless plan&.supplementary?
    return true if supplementary_plans.include?(plan)

    user_supplementary_plans.create(membership_plan: plan)
    true
  end

  # Remove a supplementary plan from this user
  def remove_supplementary_plan(plan)
    user_supplementary_plans.where(membership_plan: plan).destroy_all
  end

  # Check if user has a specific plan (primary or supplementary)
  def has_plan?(plan)
    membership_plan_id == plan.id || supplementary_plans.exists?(plan.id)
  end

  # Find user by username or ID
  def self.find_by_param(param)
    find_by(username: param) || find(param)
  end

  # Returns which greeting option is currently active: 'full_name', 'username', 'custom', or 'do_not_greet'
  def greeting_option
    return 'full_name' if use_full_name_for_greeting?
    return 'username' if use_username_for_greeting?
    return 'do_not_greet' if do_not_greet?

    'custom'
  end

  before_validation :generate_username_if_blank
  before_validation :set_membership_start_date, on: :create
  before_validation :apply_sponsored_guest_duration_months
  before_save :set_extra_email_lookup_digests
  before_save :ensure_greeting_name_mutual_exclusivity
  before_save :clear_greeting_name_if_do_not_greet
  before_save :auto_fill_greeting_name
  before_save :clear_legacy_if_meaningful_data
  before_save :clear_mailing_coordinates_if_address_changed
  before_save :mark_authentik_dirty_if_needed
  after_save :update_greeting_name_on_source_change
  after_create_commit :journal_created!
  after_create_commit :provision_to_authentik
  after_create_commit :sync_application_group_memberships_on_create
  after_create_commit :enqueue_mailing_geocoding_if_needed
  after_update_commit :journal_updated!
  after_update_commit :sync_authentik_user_if_needed
  after_update_commit :sync_application_group_memberships_on_update
  after_update_commit :enqueue_mailing_geocoding_if_needed

  private

  # Which topics can satisfy a topic-scoped check against this one: the topic itself, plus its
  # parent, whose privileges reach one level down into its subtopics.
  def privilege_conferring_topic_ids(topic)
    return [topic.id, topic.parent_id].compact if topic.is_a?(TrainingTopic)

    topic_id = topic.to_i
    [topic_id, TrainingTopic.where(id: topic_id).pick(:parent_id)].compact
  end

  def build_conferred_privileges
    sources = held_topic_member_sources
    return [] if sources.empty?

    attachments = TrainingTopicRole.includes(role: :privileges).where(training_topic_id: sources.keys)
    attachments.flat_map do |attachment|
      next [] unless sources.fetch(attachment.training_topic_id, []).include?(attachment.member_source)

      attachment.role.privileges.map { |privilege| [attachment.training_topic_id, privilege] }
    end
  end

  # Which conferral sources this member satisfies for each topic they hold.
  def held_topic_member_sources
    sources = {}
    trainings_as_trainee.distinct.pluck(:training_topic_id).each do |topic_id|
      (sources[topic_id] ||= []) << 'trained_in'
    end
    trainer_capabilities.distinct.pluck(:training_topic_id).each do |topic_id|
      (sources[topic_id] ||= []) << 'can_train'
    end
    sources
  end

  # Merge an email from an external source (Slack, PayPal, Recharge, etc.)
  # If user has no email, sets it. If different, adds to extra_emails.
  def merge_email_from_external_source(external_email, updates = {})
    return updates if external_email.blank?

    external_email_normalized = external_email.to_s.strip.downcase

    if email.blank?
      # User has no email, set it from external source
      updates[:email] = external_email
    elsif email.downcase != external_email_normalized
      # User has different primary email, add to extra_emails if not already there
      current_extra_emails = extra_emails || []
      unless current_extra_emails.map(&:downcase).include?(external_email_normalized)
        updates[:extra_emails] = current_extra_emails + [external_email]
      end
    end

    updates
  end

  # Link all Recharge payments with the given customer_id to this user.
  # Uses update_all to avoid triggering callbacks (which would cause infinite recursion).
  def link_all_recharge_payments_by_customer_id(customer_id)
    return if customer_id.blank?

    # Find all unlinked payments with this customer_id and link them
    # Use update_all to avoid triggering the after_save callback again
    RechargePayment.where(customer_id: customer_id.to_s, user_id: nil)
                   .update_all(user_id: id)
  end

  # Link all PayPal payments with the given payer_id to this user.
  # Uses update_all to avoid triggering callbacks (which would cause infinite recursion).
  def link_all_paypal_payments_by_payer_id(payer_id)
    return if payer_id.blank?

    # Find all unlinked payments with this payer_id and link them
    # Use update_all to avoid triggering the after_save callback again
    PaypalPayment.where(payer_id: payer_id.to_s, user_id: nil)
                 .update_all(user_id: id)
  end

  # Find or create PaymentEvent records for all PayPal payments with the given payer_id.
  # Updates existing orphaned events (user_id nil) and creates missing ones.
  def ensure_paypal_payment_events(payer_id)
    return if payer_id.blank?

    PaypalPayment.where(payer_id: payer_id.to_s, user_id: id).find_each do |pp|
      pe = PaymentEvent.find_or_create_by!(source: 'paypal', external_id: pp.paypal_id,
                                           event_type: 'payment') do |event|
        event.user = self
        event.amount = pp.amount
        event.currency = pp.currency || 'USD'
        event.occurred_at = pp.transaction_time || pp.created_at
        event.details = pp.payment_event_details
        event.paypal_payment = pp
      end
      pe.update!(user: self) if pe.user_id != id
    end
  end

  # Find or create PaymentEvent records for all Recharge payments with the given customer_id.
  # Updates existing orphaned events (user_id nil) and creates missing ones.
  def ensure_recharge_payment_events(customer_id)
    return if customer_id.blank?

    RechargePayment.where(customer_id: customer_id.to_s, user_id: id).find_each do |rp|
      pe = PaymentEvent.find_or_create_by!(
        source: 'recharge', external_id: rp.recharge_id, event_type: 'payment'
      ) do |event|
        event.user = self
        event.amount = rp.amount
        event.currency = rp.currency || 'USD'
        event.occurred_at = rp.processed_at || rp.created_at
        event.details = "Recharge payment from #{rp.customer_name || rp.customer_email}"
        event.recharge_payment = rp
      end
      pe.update!(user: self) if pe.user_id != id
    end
  end

  def generate_username_if_blank
    return if self[:username].present?
    return if full_name.blank?

    # Generate base username from full name: lowercase, remove special chars and spaces
    base_username = full_name.downcase
                             .gsub(/[^a-z0-9\s]/, '') # Remove special characters
                             .gsub(/\s+/, '')         # Remove all whitespace
                             .truncate(50, omission: '') # Limit length

    return if base_username.blank?

    # Find a unique username
    candidate = base_username
    counter = 1

    while User.where(username: candidate).where.not(id: id).exists?
      candidate = "#{base_username}#{counter}"
      counter += 1
    end

    self.username = candidate
  end

  def set_membership_start_date
    self.membership_start_date ||= Date.current
  end

  def journal_created!
    changes = saved_changes_to_json_hash
    # Ensure changes_json is never empty
    changes = { '_system_note' => { 'from' => nil, 'to' => 'User record created' } } if changes.empty?

    Journal.create!(
      user: self,
      actor_user: Current.actor, # nil when done by system (login, sync, etc.)
      action: 'created',
      changes_json: changes,
      changed_at: Time.current
    )
  end

  def journal_updated!
    # Skip if only noisy/internal fields changed
    return if saved_changes.except('updated_at', 'authentik_dirty', *JOURNAL_DERIVED_ATTRIBUTES).empty?

    # Skip journal when only change is marking as legacy (legacy false -> true).
    # We DO want a journal entry when un-marking legacy (true -> false).
    if saved_changes.key?('legacy')
      _, to = saved_changes['legacy']
      other_changes = saved_changes.except('updated_at', 'authentik_dirty', 'legacy',
                                           *JOURNAL_DERIVED_ATTRIBUTES)
      return if to == true && other_changes.empty?
    end

    changes = saved_changes_to_json_hash
    # Ensure changes_json is never empty
    changes = { '_system_note' => { 'from' => nil, 'to' => 'User record updated' } } if changes.empty?

    Journal.create!(
      user: self,
      actor_user: Current.actor, # nil when done by system (login, sync, etc.)
      action: 'updated',
      changes_json: changes,
      changed_at: Time.current
    )
  end

  def saved_changes_to_json_hash
    # Convert saved_changes to a { attr => { from: old, to: new } } structure,
    # and filter out noisy attributes.
    filtered = saved_changes.except('updated_at', 'created_at', 'last_synced_at', 'authentik_dirty',
                                    *JOURNAL_DERIVED_ATTRIBUTES)
    filtered.to_h do |attr, (from, to)|
      [attr, { 'from' => from, 'to' => to }]
    end
  end

  def extra_emails_format
    return if extra_emails.blank?

    extra_emails.each do |email|
      errors.add(:extra_emails, "contains invalid email: #{email}") unless email.match?(URI::MailTo::EMAIL_REGEXP)
    end
  end

  def apply_sponsored_guest_duration_months
    return unless membership_state.in?(%w[guest_member sponsored_member])
    return if sponsored_guest_duration_months.blank?

    months = sponsored_guest_duration_months.to_i
    self.dues_due_at = months.positive? ? Time.current + months.months : nil
  end

  # Auto-remove legacy flag when the account *gets* meaningful payment/membership data.
  # Only triggers when the relevant fields are actually changing in this save,
  # not when legacy itself is being set on a record that already has some data.
  # This triggers a journal entry (un-marking legacy is journaled).
  def clear_legacy_if_meaningful_data
    return unless legacy?

    # Only auto-clear if one of the meaningful data fields is changing in this save
    meaningful_fields = %w[membership_plan_id last_payment_date recharge_most_recent_payment_date
                           membership_state is_sponsored dues_due_at]
    return unless changes.keys.intersect?(meaningful_fields)

    has_plan = membership_plan_id.present?
    has_payment_date = last_payment_date.present? || recharge_most_recent_payment_date.present?
    has_determined_membership = membership_state != 'unknown'

    return unless has_plan || has_payment_date || has_determined_membership || is_sponsored?

    self.legacy = false
  end

  def clear_greeting_name_if_do_not_greet
    self.greeting_name = nil if do_not_greet?
  end

  def auto_fill_greeting_name
    return if do_not_greet?

    if use_full_name_for_greeting?
      self.greeting_name = full_name if full_name.present?
    elsif use_username_for_greeting?
      self.greeting_name = username if username.present?
    end
  end

  def update_greeting_name_on_source_change
    # Update greeting_name if the source field changed and the corresponding boolean is set
    return if do_not_greet?

    if saved_change_to_full_name? && use_full_name_for_greeting?
      update_column(:greeting_name, full_name) if full_name.present?
    elsif (saved_change_to_authentik_id? || saved_change_to_username?) && use_username_for_greeting?
      update_column(:greeting_name, username) if username.present?
    end
  end

  def ensure_greeting_name_mutual_exclusivity
    if do_not_greet?
      self.use_full_name_for_greeting = false
      self.use_username_for_greeting = false
      return
    end

    self.use_username_for_greeting = false if use_full_name_for_greeting? && use_username_for_greeting?

    self.do_not_greet = false if use_full_name_for_greeting? || use_username_for_greeting?
  end

  # Fields that correspond to Authentik user attributes
  AUTHENTIK_SYNCABLE_FIELDS = (
    Authentik::UserSync::SYNCABLE_FIELDS + Authentik::UserSync::ATTRIBUTE_SYNC_FIELDS
  ).freeze
  private_constant :AUTHENTIK_SYNCABLE_FIELDS

  # Mark user as needing sync to Authentik when syncable fields change
  def mark_authentik_dirty_if_needed
    return if Current.skip_authentik_sync

    changed = changes.keys & AUTHENTIK_SYNCABLE_FIELDS
    return if changed.empty?

    self.authentik_dirty = true
  end

  def clear_mailing_coordinates_if_address_changed
    return unless will_save_change_to_mailing_address?

    self.mailing_latitude = nil
    self.mailing_longitude = nil
    self.mailing_geocoded_at = nil
  end

  def enqueue_mailing_geocoding_if_needed
    return unless saved_change_to_mailing_address?
    return if mailing_address.blank?

    MemberGeocodingJob.perform_later(id)
  end

  def provision_to_authentik
    return if Current.skip_authentik_sync

    Authentik::ProvisionUserJob.perform_later(id)
  end

  def sync_authentik_user_if_needed
    return if Current.skip_authentik_sync

    changed_fields = saved_changes.keys & AUTHENTIK_SYNCABLE_FIELDS
    return if changed_fields.empty?

    if authentik_id.present?
      Authentik::UserSyncJob.perform_later(id, changed_fields)
    else
      Authentik::ProvisionUserJob.perform_later(id)
    end
  end

  def sync_application_group_memberships_on_create
    return if Current.skip_authentik_sync

    sources = %w[all_members]
    sources << 'active_members' if active?
    sources << 'unbanned_members' unless banned?
    sources << 'admin_members' if is_admin?

    Authentik::ApplicationGroupMembershipSyncJob.perform_later(sources)
  end

  def sync_application_group_memberships_on_update
    return if Current.skip_authentik_sync

    sources = []

    sources << 'active_members' if saved_change_to_active?

    if saved_change_to_membership_status?
      old_status, new_status = saved_change_to_membership_status
      if old_status == 'banned' || new_status == 'banned'
        sources << 'unbanned_members'
        sources << 'active_members' unless sources.include?('active_members')
      end
    end

    sources << 'admin_members' if saved_change_to_is_admin?

    if saved_change_to_authentik_id? && authentik_id.present?
      sources << 'all_members'
      sources << 'active_members' if active?
      sources << 'unbanned_members' unless banned?
      sources << 'admin_members' if is_admin?
    end

    return if sources.empty?

    sources << 'all_members'
    Authentik::ApplicationGroupMembershipSyncJob.perform_later(sources.uniq)
  end
end
