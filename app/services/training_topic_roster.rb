# Who may see and message the members trained in one topic.
#
# Admins always may. So may a member trained in the topic's direct parent: holding the
# parent means they run that area, so a woodshop steward sees everyone trained on the
# table saw without any setting. Everyone else may only when the topic itself opts in,
# one setting for the list and one for sending a message.
class TrainingTopicRoster
  # Active members trained in topics that show their names, grouped by topic id.
  # A topic that only allows contact is left out, so the catalog cannot print
  # people the topic has not agreed to show.
  def self.active_members_by_topic(topics)
    topic_ids = Array(topics).select(&:trained_members_visible?).map(&:id)
    return {} if topic_ids.empty?

    grouped = Hash.new { |members, topic_id| members[topic_id] = [] }
    active_trained_in(topic_ids).each do |training|
      bucket = grouped[training.training_topic_id]
      bucket << training.trainee unless bucket.include?(training.trainee)
    end
    grouped
  end

  def self.active_trained_in(topic_ids)
    Training.joins(:trainee).merge(User.active)
            .where(training_topic_id: topic_ids)
            .includes(:trainee)
            .order(User.arel_table[:full_name].asc, User.arel_table[:id].asc)
  end
  private_class_method :active_trained_in

  def initialize(topic:, viewer:)
    @topic = topic
    @viewer = viewer
  end

  def list_visible?
    oversight? || topic.trained_members_visible?
  end

  def contactable?
    oversight? || topic.trained_members_contactable?
  end

  # Oversight sees inactive members too, so an area lead can tell who has lapsed.
  # The public list is active members only, the same people a message would reach.
  def members
    return User.none unless list_visible?

    scope = trained_members
    scope = scope.merge(User.active) unless oversight?
    scope.order(:full_name, :id)
  end

  def active_trained_count
    trained_members.merge(User.active).distinct.count(:id)
  end

  # Active trained members, excluding the viewer and whoever is about to send.
  def recipients(except: nil)
    return User.none unless contactable?

    excluded_ids = [viewer&.id, except&.id].compact.uniq
    scope = trained_members.merge(User.active)
    scope = scope.where.not(id: excluded_ids) if excluded_ids.any?
    scope.order(:full_name, :id)
  end

  # A name links when the viewer could open that profile. Admins, and anyone allowed
  # to read every profile, always can. Everyone else only reaches a profile its owner
  # has shared with members or the public.
  def profile_linked?(member)
    return false if member.nil?
    return true if viewer&.is_admin? || viewer&.can?(:'members.view_profile')

    User::SHARED_PROFILE_VISIBILITIES.include?(member.profile_visibility)
  end

  private

  attr_reader :topic, :viewer

  def oversight?
    viewer&.is_admin? || topic.parent_held_by?(viewer)
  end

  def trained_members
    User.where(id: topic.trainings.select(:trainee_id))
  end
end
