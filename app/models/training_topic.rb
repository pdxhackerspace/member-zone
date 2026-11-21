class TrainingTopic < ApplicationRecord
  # Topics nest one area inside another (Shop > CNC). Privileges reach one level down:
  # holding a topic-scoped privilege for a parent grants it for that parent's direct
  # children. See User#topic_scoped_privilege_keys.
  belongs_to :parent, class_name: 'TrainingTopic', optional: true
  has_many :children, class_name: 'TrainingTopic', foreign_key: :parent_id,
                      dependent: :nullify, inverse_of: :parent

  has_many :trainer_capabilities, dependent: :destroy
  has_many :trainers, through: :trainer_capabilities, source: :user
  has_many :trainings, dependent: :destroy
  has_many :training_requests, dependent: :destroy
  has_many :links, class_name: 'TrainingTopicLink', dependent: :destroy
  has_many :document_training_topics, dependent: :destroy
  has_many :documents, through: :document_training_topics
  has_many :application_groups, dependent: :destroy
  has_many :topic_roles, class_name: 'TrainingTopicRole', dependent: :destroy
  has_many :credential_provider_training_topics, dependent: :restrict_with_error
  has_many :roles, through: :topic_roles

  validates :name, presence: true, uniqueness: true
  validates :offered_to_members, inclusion: { in: [true, false] }
  validates :trained_members_visible, inclusion: { in: [true, false] }
  validates :trained_members_contactable, inclusion: { in: [true, false] }
  validate :parent_is_not_self
  validate :parent_is_not_a_descendant

  scope :roots, -> { where(parent_id: nil) }
  scope :offered_for_members, -> { where(offered_to_members: true) }
  # Topics a member may open just to see or message the people trained in them,
  # even when the topic itself is not offered for training requests.
  scope :roster_shared, lambda {
    where(trained_members_visible: true).or(where(trained_members_contactable: true))
  }
  scope :with_trainers, -> { joins(:trainer_capabilities).distinct }
  # Only counts trainers whose membership is still active; inactive trainers
  # are not contacted, so topics whose only trainers are inactive are not
  # offered for member requests.
  scope :with_active_trainers, -> { joins(:trainers).merge(User.active).distinct }
  scope :available_for_member_requests, -> { offered_for_members.with_active_trainers.order(:name) }

  after_create_commit :provision_authentik_groups

  # The topic whose training moves a new member out of new_member and into their
  # pre-payment grace period. Configured under Membership Settings; falls back to
  # matching on name so installs that have not set it yet keep working.
  def self.building_access
    MembershipSetting.building_access_training_topic || find_by('LOWER(name) LIKE ?', '%building access%')
  end

  def building_access?
    id == TrainingTopic.building_access&.id
  end

  # Privileges this topic confers, optionally limited to one conferral source.
  def conferred_privileges(member_sources: TrainingTopicRole::MEMBER_SOURCES)
    Privilege.joins(roles: :topic_roles)
             .where(training_topic_roles: { training_topic_id: id, member_source: member_sources })
             .distinct
  end

  # Only global privileges are subject to the no-escalation rule; see User#may_confer?.
  def conferred_global_privilege_keys(member_sources: TrainingTopicRole::MEMBER_SOURCES)
    conferred_privileges(member_sources: member_sources).global.pluck(:key)
  end

  # Topics carrying roles hand out privileges, so conferring them is gated more tightly.
  def privilege_bearing?
    topic_roles.exists?
  end

  # Active trainers to tell about something on this topic. Inactive trainers are left out,
  # matching a training request, which only emails trainers whose membership is still active.
  def notifiable_trainers(except:)
    scope = trainers.active.order(:full_name, :id)
    ids = Array(except).filter_map(&:id)
    return scope if ids.empty?

    scope.where.not(id: ids)
  end

  # Roots first, each followed by its own subtopics, as [topic, depth] pairs for rendering the
  # tree as a flat list. Anything orphaned or circular is appended rather than silently dropped.
  def self.tree_ordered
    topics = all.to_a
    by_parent = topics.group_by(&:parent_id)
    visited = Set.new
    ordered = []

    append_branch = lambda do |parent_id, depth|
      (by_parent[parent_id] || []).sort_by { |topic| topic.name.to_s.downcase }.each do |topic|
        next unless visited.add?(topic.id)

        ordered << [topic, depth]
        append_branch.call(topic.id, depth + 1)
      end
    end
    append_branch.call(nil, 0)

    ordered + topics.reject { |topic| visited.include?(topic.id) }.map { |topic| [topic, 0] }
  end

  def root?
    parent_id.nil?
  end

  def subtopic?
    parent_id.present?
  end

  def roster_shared?
    trained_members_visible? || trained_members_contactable?
  end

  # A member trained in this topic's direct parent runs the area it belongs to, so they
  # can see and contact everyone trained here. Reach stops after one level: holding the
  # grandparent does not.
  def parent_held_by?(user)
    return false if user.nil? || parent_id.blank?

    Training.exists?(trainee_id: user.id, training_topic_id: parent_id)
  end

  # Topics that may be chosen as this topic's parent: anything but itself and its own
  # descendants, since either would close a loop.
  def eligible_parents
    return TrainingTopic.order(:name) unless persisted?

    TrainingTopic.where.not(id: [id, *descendant_ids]).order(:name)
  end

  # Walks the tree downward. Tracks what it has already seen rather than trusting the data to
  # be acyclic, since this backs the validation that keeps it that way.
  def descendant_ids
    collected = []
    frontier = children.pluck(:id)

    while frontier.any?
      collected.concat(frontier)
      frontier = TrainingTopic.where(parent_id: frontier).pluck(:id) - collected
    end

    collected
  end

  private

  def parent_is_not_self
    return if parent_id.blank? || parent_id != id

    errors.add(:parent_id, 'cannot be the topic itself')
  end

  def parent_is_not_a_descendant
    return if parent_id.blank? || !persisted? || parent_id == id
    return unless descendant_ids.include?(parent_id)

    errors.add(:parent_id, "cannot be one of this topic's own subtopics")
  end

  def provision_authentik_groups
    defaults = DefaultSetting.instance
    app = Authentik::CoreGroupProvisioner.system_application
    slug = name.parameterize

    app.application_groups.find_or_create_by!(member_source: 'trained_in', training_topic: self) do |g|
      g.name = "Trained: #{name}"
      g.authentik_name = "#{defaults.trained_on_prefix}:#{slug}"
    end

    app.application_groups.find_or_create_by!(member_source: 'can_train', training_topic: self) do |g|
      g.name = "Can Train: #{name}"
      g.authentik_name = "#{defaults.can_train_prefix}:#{slug}"
    end
  rescue StandardError => e
    Rails.logger.error("[TrainingTopic] Failed to provision Authentik groups for '#{name}': #{e.message}")
  end
end
