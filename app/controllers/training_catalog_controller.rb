# Member-facing catalog of training topics.
#
# Admins see every topic. Non-admins see topics offered to members, any whose edit page they
# may open (stewards and curators), and any they are already trained in. Each topic has a detail
# page showing trainers, trainees, and training materials (links + documents).
# From the detail page, both admins and non-admins can request training
# for any topic that is offered to members and has at least one trainer.
class TrainingCatalogController < AuthenticatedController
  before_action :set_training_topic, only: :show
  before_action :authorize_topic_visibility!, only: :show

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
    @can_record_training = current_user_admin? ? TrainingTopic.exists? : current_user.trainer_capabilities.exists?
  end

  def show
    trainers_scope = @training_topic.trainers.order(:full_name, :id)
    @trainers = current_user_admin? ? trainers_scope : trainers_scope.active
    @trainees = User.where(id: @training_topic.trainings.select(:trainee_id).distinct)
                    .order(:full_name, :id)
    @topic_links = @training_topic.links.order(:title)
    @requestable = @training_topic.offered_to_members? &&
                   @training_topic.trainers.active.exists?
    @can_manage_links = can?(:'training.topics.manage') ||
                        can?(:'training.topics.manage_links', topic: @training_topic)
    @can_manage_documents = can_manage_topic_documents?(@training_topic)
    @topic_documents = visible_documents_for(@training_topic)
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

  # Roots first, each followed by its subtopics. Depth comes from the full tree, so a
  # visible subtopic stays indented when its parent is hidden from this viewer.
  def ordered_visible_topics
    visible_ids = visible_topics.pluck(:id).to_set
    TrainingTopic.includes(:parent).tree_ordered.select { |topic, _depth| visible_ids.include?(topic.id) }
  end

  def filtered_training_topics(ordered)
    case params[:training_filter]
    when 'offered'
      ordered.select { |topic, _depth| topic.offered_to_members? }
    when 'needs_trainers'
      ordered.select { |topic, _depth| needs_trainers?(topic) }
    else
      ordered
    end
  end

  # Nil means every topic is linkable: admins, and anyone who may view the whole catalog.
  # Otherwise a name links when a member can request the topic, the viewer is trained in
  # it, or the viewer may open its page.
  def linked_catalog_topic_ids
    return if current_user_admin? || can?(:'training.catalog.view_all')

    @trainable_on_request_topic_ids |
      @trained_topic_ids |
      current_user.topics_with_page_access.pluck(:id).to_set
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
    return if current_user_admin? || can?(:'training.catalog.view_all')
    return if @training_topic.offered_to_members?
    return if current_user.may_open_topic_page?(@training_topic)
    return if Training.exists?(trainee: current_user, training_topic: @training_topic)

    redirect_to training_catalog_path, alert: 'That training topic is not available.'
  end

  # A privilege here only ever widens what a member sees: every member keeps the topics on
  # offer, training.catalog.view_all adds the ones that are not, a steward or curator also
  # sees the unoffered topics whose page they may edit, and a member sees topics they hold.
  def visible_topics
    return TrainingTopic.all if current_user_admin? || can?(:'training.catalog.view_all')

    held_ids = Training.where(trainee: current_user).select(:training_topic_id)
    TrainingTopic.offered_for_members
                 .or(TrainingTopic.where(id: current_user.topics_with_page_access.select(:id)))
                 .or(TrainingTopic.where(id: held_ids))
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
