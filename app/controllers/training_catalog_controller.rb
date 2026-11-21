# Member-facing catalog of training topics.
#
# Admins see every topic. Non-admins see topics offered to members, any whose edit page they
# may open (stewards and curators), any they are already trained in, and the direct subtopics
# of those. Each topic has a detail page showing trainers, the members trained in it when the
# viewer is allowed to see them, and training materials (links + documents).
# From the detail page, both admins and non-admins can request training
# for any topic that is offered to members and has at least one trainer, and can message the
# trained members when the topic allows it.
class TrainingCatalogController < AuthenticatedController
  before_action :set_training_topic, only: %i[show contact]
  before_action :authorize_topic_visibility!, only: %i[show contact]
  rate_limit to: 10, within: 1.hour, only: :contact, name: 'training-topic-contact',
             store: RateLimiting.store, by: -> { true_user&.id },
             with: -> { training_contact_rate_limited }

  def index
    ordered = ordered_visible_topics
    prepare_training_catalog_counts(ordered.map(&:first))
    @training_topics = filtered_training_topics(ordered)

    # Offered topics that have an active trainer. `reorder(nil)` drops the scope's
    # `order(:name)` so Postgres accepts the `DISTINCT id` select. Topics the viewer
    # already holds stay linkable, but drop out of the request buttons.
    @trainable_on_request_topic_ids = TrainingTopic.available_for_member_requests
                                                   .reorder(nil)
                                                   .pluck(:id)
                                                   .to_set
    @requestable_topic_ids = @trainable_on_request_topic_ids - @trained_topic_ids
    @linked_topic_ids = linked_catalog_topic_ids
    @contactable_topic_ids = contactable_catalog_topic_ids
    @roster_members = TrainingTopicRoster.active_members_by_topic(@training_topics.map(&:first))
    @can_record_training = current_user_admin? ? TrainingTopic.exists? : current_user.trainer_capabilities.exists?
  end

  def show
    @roster = TrainingTopicRoster.new(topic: @training_topic, viewer: current_user)
    trainers_scope = @training_topic.trainers.order(:full_name, :id)
    @trainers = current_user_admin? ? trainers_scope : trainers_scope.active
    @trainees = @roster.members
    @contact_recipient_count = @roster.recipients(except: true_user).count
    @topic_links = @training_topic.links.includes(:content_snapshot).order(:title)
    @requestable = @training_topic.offered_to_members? &&
                   @training_topic.trainers.active.exists?
    @can_manage_links = can?(:'training.topics.manage') ||
                        can?(:'training.topics.manage_links', topic: @training_topic)
    @can_manage_documents = can_manage_topic_documents?(@training_topic)
    @topic_documents = visible_documents_for(@training_topic)
  end

  def contact
    result = TrainingTopicContact.new(
      topic: @training_topic, viewer: current_user, sender: true_user,
      subject: params[:subject], body: params[:body]
    ).deliver

    if result.error
      redirect_to after_contact_path, alert: result.error
    else
      notice = "Message sent to #{result.sent_count} #{'member'.pluralize(result.sent_count)}."
      redirect_to after_contact_path, notice: notice
    end
  end

  private

  def prepare_training_catalog_counts(topics)
    topic_ids = topics.map(&:id)
    @all_topic_count = topics.size
    @topic_trainer_counts = topic_member_status_counts(
      TrainerCapability, topic_ids, user_association: :user, member_column: :user_id
    )
    @topic_trained_counts = topic_member_status_counts(
      Training, topic_ids, user_association: :trainee, member_column: :trainee_id
    )
    @trained_topic_ids = Training.where(trainee: current_user).pluck(:training_topic_id).to_set
    @needs_trainers_count = topics.count { |topic| needs_trainers?(topic) }
    @offered_topic_count = topics.count(&:offered_to_members?)
  end

  def topic_member_status_counts(model, topic_ids, user_association:, member_column:)
    return {} if topic_ids.empty?

    total_by_topic = model.where(training_topic_id: topic_ids)
                          .group(:training_topic_id)
                          .distinct
                          .count(member_column)
    active_by_topic = model.where(training_topic_id: topic_ids)
                           .joins(user_association)
                           .merge(User.active)
                           .group(:training_topic_id)
                           .distinct
                           .count(member_column)

    topic_ids.index_with do |topic_id|
      total = total_by_topic[topic_id].to_i
      active = active_by_topic[topic_id].to_i
      { total: total, active: active, inactive: total - active }
    end
  end

  # Roots first, each followed by its subtopics. A parent stays in the list when one of
  # its topics is visible, even if the parent itself is not offered to members.
  def ordered_visible_topics
    visible_ids = visible_topics.pluck(:id).to_set
    ordered = TrainingTopic.tree_ordered
    display_ids = visible_ids | ancestor_ids(ordered, visible_ids)
    ordered.select { |topic, _depth| display_ids.include?(topic.id) }
  end

  def ancestor_ids(ordered, topic_ids)
    by_id = ordered.to_h { |topic, _depth| [topic.id, topic] }
    ids = Set.new
    topic_ids.each do |id|
      parent_id = by_id[id]&.parent_id
      parent_id = by_id[parent_id]&.parent_id while parent_id && ids.add?(parent_id)
    end
    ids
  end

  def filtered_training_topics(ordered)
    matched = case params[:training_filter]
              when 'offered'
                ordered.select { |topic, _depth| topic.offered_to_members? }
              when 'needs_trainers'
                ordered.select { |topic, _depth| needs_trainers?(topic) }
              else
                return ordered
              end

    keep_ids = matched.to_set { |topic, _depth| topic.id }
    keep_ids.merge(ancestor_ids(ordered, keep_ids))
    ordered.select { |topic, _depth| keep_ids.include?(topic.id) }
  end

  # Nil means every topic is linkable: admins, and anyone who may view the whole catalog.
  # Otherwise a name links when a member can request the topic, the topic shares its
  # roster, the viewer is trained in it or its parent, or the viewer may open its page.
  def linked_catalog_topic_ids
    return if current_user_admin? || can?(:'training.catalog.view_all')

    @trainable_on_request_topic_ids |
      @trained_topic_ids |
      current_user.topics_with_page_access.pluck(:id).to_set |
      TrainingTopic.where(parent_id: @trained_topic_ids.to_a).pluck(:id).to_set |
      TrainingTopic.roster_shared.pluck(:id).to_set
  end

  # Topics whose row offers Contact: the viewer may message, and someone else active
  # is trained there. Request stays the row's button when the topic is requestable.
  def contactable_catalog_topic_ids
    Training.joins(:trainee).merge(User.active)
            .where(training_topic_id: topics_viewer_may_contact.select(:id))
            .where.not(trainee_id: current_user.id)
            .distinct
            .pluck(:training_topic_id)
            .to_set
  end

  def topics_viewer_may_contact
    return TrainingTopic.all if current_user_admin?

    TrainingTopic.where(trained_members_contactable: true)
                 .or(TrainingTopic.where(parent_id: @trained_topic_ids.to_a))
  end

  def needs_trainers?(topic)
    topic.offered_to_members? && @topic_trainer_counts.dig(topic.id, :active).to_i.zero?
  end

  def set_training_topic
    @training_topic = TrainingTopic.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to training_catalog_path, alert: 'Training topic not found.'
  end

  def authorize_topic_visibility!
    return if topic_visible_to_current_user?

    redirect_to training_catalog_path, alert: 'That training topic is not available.'
  end

  def topic_visible_to_current_user?
    return true if current_user_admin? || can?(:'training.catalog.view_all')
    return true if @training_topic.offered_to_members?
    return true if current_user.may_open_topic_page?(@training_topic)
    return true if Training.exists?(trainee: current_user, training_topic: @training_topic)
    return true if @training_topic.roster_shared?

    @training_topic.parent_held_by?(current_user)
  end

  def training_contact_rate_limited
    redirect_to after_contact_path, alert: 'Too many messages. Try again in an hour.'
  end

  # The catalog list sends its own message, and lands back on the list.
  def after_contact_path
    return training_catalog_path if params[:return_to] == 'catalog'

    training_catalog_topic_path(@training_topic)
  end

  # A privilege here only ever widens what a member sees: every member keeps the topics on
  # offer, training.catalog.view_all adds the ones that are not, a steward or curator also
  # sees the unoffered topics whose page they may edit, a member sees topics they hold, and
  # holding a topic reveals its direct subtopics, and a topic that shares its roster
  # is listed even when it is not offered.
  def visible_topics
    return TrainingTopic.all if current_user_admin? || can?(:'training.catalog.view_all')

    held_ids = Training.where(trainee: current_user).select(:training_topic_id)
    TrainingTopic.offered_for_members
                 .or(TrainingTopic.roster_shared)
                 .or(TrainingTopic.where(id: current_user.topics_with_page_access.select(:id)))
                 .or(TrainingTopic.where(id: held_ids))
                 .or(TrainingTopic.where(parent_id: held_ids))
  end

  # Mirrors DocumentsController#manageable_topic_ids, which decides what the links lead to.
  def can_manage_topic_documents?(topic)
    return true if current_user_admin?

    current_user.training_topics.exists?(topic.id) ||
      current_user.topics_with_privilege(:'training.documents.manage').exists?(topic.id)
  end

  # Non-admins may only see documents they are allowed to download (trained in the topic,
  # a trainer for it, able to manage its documents, or marked `show_on_all_profiles`).
  def visible_documents_for(topic)
    documents = topic.documents.ordered
    return documents if @can_manage_documents || can?(:'training.documents.view_all')

    trained = Training.exists?(trainee: current_user, training_topic: topic)
    trainer = TrainerCapability.exists?(user: current_user, training_topic: topic)
    return documents if trained || trainer

    documents.where(show_on_all_profiles: true)
  end
end
