class ApplicationGroup < ApplicationRecord
  MEMBER_SOURCES = %w[manual active_members admin_members unbanned_members all_members sync_group can_train
                      trained_in].freeze

  POLICY_NAME_PREFIX = 'mm-group-membership'.freeze

  belongs_to :application
  belongs_to :training_topic, optional: true
  belongs_to :sync_with_group, class_name: 'ApplicationGroup', optional: true, inverse_of: :sync_dependents
  has_many :sync_dependents, class_name: 'ApplicationGroup', foreign_key: :sync_with_group_id,
                             dependent: :restrict_with_error, inverse_of: :sync_with_group
  has_and_belongs_to_many :users,
                          after_add: :queue_authentik_membership_sync,
                          after_remove: :queue_authentik_membership_sync

  validates :name, presence: true
  validates :authentik_name, presence: true,
                             format: { with: %r{\A[\w\-.:/ ]+\z},
                                       message: 'may only contain letters, numbers, hyphens, ' \
                                                'underscores, periods, colons, slashes, and spaces' }
  validates :member_source, presence: true, inclusion: { in: MEMBER_SOURCES }
  validates :training_topic_id, presence: true, if: -> { can_train? || trained_in? }
  validates :sync_with_group_id, presence: true, if: -> { sync_group? }

  before_save :clear_authentik_group_id_if_name_changed
  before_save :clear_irrelevant_associations

  scope :with_authentik_group_id, -> { where.not(authentik_group_id: [nil, '']) }
  scope :ordered_by_name, -> { order(:name) }
  scope :with_member_sources, ->(*sources) { where(member_source: sources.flatten) }

  # Groups that hang off the built-in Member Zone application: the provisioned ones
  # (active members, training, and so on) and the hand-managed custom core groups.
  def self.core
    application = Authentik::CoreGroupProvisioner.existing_system_application
    return none if application.nil?

    where(application_id: application.id)
  end

  def self.custom_core
    core.with_member_sources('manual')
  end

  def self.builtin_core
    core.where.not(member_source: 'manual')
  end

  def self.synced_authentik_group_ids
    with_authentik_group_id.pluck(:authentik_group_id).compact.uniq
  end

  MEMBER_SOURCES.each do |source|
    define_method(:"#{source}?") { member_source == source }
  end

  def uses_default_group?
    member_source != 'manual'
  end

  def effective_members
    case member_source
    when 'active_members'
      User.active
    when 'admin_members'
      User.admin
    when 'unbanned_members'
      User.non_service_accounts.where.not(membership_status: 'banned')
    when 'all_members'
      User.non_service_accounts
    when 'sync_group'
      sync_with_group&.effective_members || User.none
    when 'can_train'
      training_topic&.trainers || User.none
    when 'trained_in'
      if training_topic
        trained_user_ids = User.joins(:trainings_as_trainee)
                               .where(trainings: { training_topic_id: training_topic_id })
                               .select(:id)

        User.where(id: trained_user_ids)
      else
        User.none
      end
    else
      users
    end
  end

  def syncable_members
    effective_members.where.not(authentik_id: [nil, ''])
  end

  def unsyncable_members
    effective_members.where(authentik_id: [nil, ''])
  end

  def policy_name
    "#{POLICY_NAME_PREFIX}:#{authentik_name}"
  end

  def policy_expression
    if sync_group? && sync_with_group.present?
      %(return ak_is_group_member(request.user, name="#{sync_with_group.authentik_name}"))
    else
      %(return ak_is_group_member(request.user, name="#{authentik_name}"))
    end
  end

  def policy_only?
    %w[sync_group can_train trained_in].include?(member_source)
  end

  # Named for the destroy screens. restrict_with_error is the backstop for any caller
  # that skips the message; the database foreign key refuses the delete either way.
  def deletion_blocked_message
    labels = sync_dependents.includes(:application).ordered_by_name.map do |group|
      "#{group.name} (#{group.application.name})"
    end
    return if labels.empty?

    "Used by #{labels.to_sentence}."
  end

  private

  def clear_authentik_group_id_if_name_changed
    return if new_record?
    return unless authentik_name_changed?
    return if authentik_group_id.blank?

    self.authentik_group_id = nil
  end

  def clear_irrelevant_associations
    self.sync_with_group_id = nil unless sync_group?
    return if can_train? || trained_in?

    self.training_topic_id = nil
  end

  def queue_authentik_membership_sync(_user)
    return if Current.skip_authentik_sync

    Authentik::ApplicationGroupMembershipSyncJob.perform_later([member_source])
  end
end
