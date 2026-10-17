# Manages training topics. Topic setup needs training.topics.manage; curators reach the topic
# page for the topics whose resources or documents they look after, and for the subtopics
# nested directly under those.
class TrainingTopicsController < AuthenticatedController
  # Any one of these is enough to reach a topic's page; each unlocks a different part of it.
  before_action :set_training_topic, only: %i[edit update destroy revoke_training revoke_trainer_capability]
  before_action -> { require_privilege!(:'training.topics.manage') }, only: %i[index]
  before_action :require_destroy_permission!, only: %i[destroy]
  before_action :require_create_permission!, only: %i[create]
  before_action :require_topic_page_access!, only: %i[edit update]
  before_action :require_revoke_training_permission!, only: %i[revoke_training]
  before_action :require_trainer_capability_permission!, only: %i[revoke_trainer_capability]

  def index
    @training_topics = TrainingTopic.includes(:parent).tree_ordered
    @eligible_parents = TrainingTopic.order(:name)
  end

  def edit
    load_edit_associations
  end

  def create
    @training_topic = TrainingTopic.new(training_topic_params)

    if @training_topic.save
      redirect_to after_create_path, notice: 'Training topic created successfully.'
    elsif can?(:'training.topics.manage')
      @training_topics = TrainingTopic.includes(:parent).tree_ordered
      @eligible_parents = TrainingTopic.order(:name)
      render :index, status: :unprocessable_content
    else
      redirect_to edit_training_topic_path(@training_topic.parent_id),
                  alert: @training_topic.errors.full_messages.to_sentence
    end
  end

  def update
    if @training_topic.update(permitted_update_params)
      redirect_to edit_training_topic_path(@training_topic), notice: 'Training topic updated successfully.'
    else
      load_edit_associations
      render :edit, status: :unprocessable_content
    end
  end

  def revoke_training
    user = User.find(params[:user_id])

    # Delete all trainings for this user and topic
    deleted_count = @training_topic.trainings.where(trainee: user).destroy_all.count

    if deleted_count.positive?
      redirect_to edit_training_topic_path(@training_topic), notice: "Training revoked for #{user.display_name}."
    else
      redirect_to edit_training_topic_path(@training_topic),
                  alert: "No training found to revoke for #{user.display_name}."
    end
  end

  def revoke_trainer_capability
    user = User.find(params[:user_id])

    # Delete the trainer capability
    trainer_capability = TrainerCapability.find_by(user: user, training_topic: @training_topic)

    if trainer_capability&.destroy
      redirect_to edit_training_topic_path(@training_topic),
                  notice: "Trainer capability revoked for #{user.display_name}."
    else
      redirect_to edit_training_topic_path(@training_topic),
                  alert: "No trainer capability found to revoke for #{user.display_name}."
    end
  end

  def destroy
    parent = @training_topic.parent

    if @training_topic.trainings.any? || @training_topic.trainer_capabilities.any?
      redirect_to after_destroy_path(parent),
                  alert: 'Cannot delete training topic that has trainings or trainer capabilities.'
    else
      @training_topic.destroy
      redirect_to after_destroy_path(parent), notice: 'Training topic deleted successfully.'
    end
  end

  private

  def set_training_topic
    @training_topic = TrainingTopic.find(params[:id])
  end

  def require_topic_page_access!
    return if current_user&.may_open_topic_page?(@training_topic)

    redirect_to root_path, alert: "You don't have permission to manage that training topic."
  end

  # Creating a top-level topic is global setup, but an area lead can add subtopics beneath a
  # topic they already hold without being able to start new areas of their own.
  def require_create_permission!
    return if can?(:'training.topics.manage')

    parent = TrainingTopic.find_by(id: training_topic_params[:parent_id])
    return if parent && can?(:'training.subtopics.create', topic: parent)

    redirect_to root_path, alert: "You don't have permission to create training topics."
  end

  # Deleting a topic is global setup, except for subtopics: a role on the parent carries
  # authority over what hangs beneath it.
  def require_destroy_permission!
    return if current_user&.may_manage_subtopic?(@training_topic)

    redirect_to root_path, alert: "You don't have permission to delete that training topic."
  end

  # Topic setup (visibility and where a topic sits in the tree) needs the global privilege.
  # A role on the parent adds renaming for its subtopics, and curators can edit descriptions.
  def permitted_update_params
    return training_topic_params if can?(:'training.topics.manage')

    allowed = []
    allowed << :description if can?(:'training.topics.edit_details', topic: @training_topic)
    allowed << :name if current_user&.may_manage_subtopic?(@training_topic)

    training_topic_params.slice(*allowed)
  end

  def after_create_path
    can?(:'training.topics.manage') ? training_topics_path : edit_training_topic_path(@training_topic)
  end

  # Subtopic managers cannot see the topic index, so send them back to the parent they came from.
  def after_destroy_path(parent)
    return training_topics_path if can?(:'training.topics.manage')

    parent ? edit_training_topic_path(parent) : root_path
  end

  # Revoking training removes privileges, so it is gated the same way granting is: a trainer
  # must not be able to strip a director of theirs.
  def require_revoke_training_permission!
    return if current_user&.may_revoke_training?(@training_topic)

    redirect_to edit_training_topic_path(@training_topic),
                alert: "You don't have permission to revoke training for that topic."
  end

  def require_trainer_capability_permission!
    return if current_user&.may_manage_trainer_capability?(@training_topic)

    redirect_to edit_training_topic_path(@training_topic),
                alert: 'You do not have permission to manage trainer capabilities.'
  end

  def load_edit_associations
    trained_user_ids = Training.where(training_topic_id: @training_topic.id).select(:trainee_id).distinct
    @trained_users = User.where(id: trained_user_ids).order(:full_name, :id)
    @trainer_users = @training_topic.trainers.order(:full_name, :id)
    @users_for_search = User.ordered_by_display_name
    @topic_documents = @training_topic.documents.ordered
    @topic_roles = @training_topic.topic_roles.joins(:role).includes(role: :privileges).order('roles.name')
    @available_roles = Role.ordered
    @subtopics = @training_topic.children.order(:name)
    @eligible_parents = @training_topic.eligible_parents
  end

  def training_topic_params
    params.expect(training_topic: %i[name offered_to_members description parent_id])
  end
end
