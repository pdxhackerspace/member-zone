class TrainingsController < AuthenticatedController
  include TrainerCapabilityActions

  before_action :require_trainer_or_admin
  before_action :prepare_record_training_form, only: :record
  # rubocop:disable Rails/LexicallyScopedActionFilter -- trainer capability actions live in TrainerCapabilityActions
  before_action :set_trainee,
                only: %i[add_training remove_training add_trainer_capability remove_trainer_capability]
  before_action :set_training_topic,
                only: %i[add_training remove_training add_trainer_capability remove_trainer_capability]
  # rubocop:enable Rails/LexicallyScopedActionFilter

  def index = redirect_to(record_training_path)

  def record; end

  def create_bulk
    training_topic = TrainingTopic.find(params[:training_topic_id])
    unless can_train_topic?(training_topic)
      redirect_to record_training_path, alert: "You don't have permission to train #{training_topic.name}."
      return
    end

    trainee_ids = Array(params[:trainee_ids]).compact_blank.uniq
    if trainee_ids.empty?
      redirect_to record_training_path, alert: 'Add at least one member before recording training.'
      return
    end

    trainer = selected_trainer_for_recording
    trained_at = parsed_trained_at
    result = TrainingRecorder.new(
      current_user: true_user,
      training_topic: training_topic,
      trainee_ids: trainee_ids,
      trainer: trainer,
      trained_at: trained_at,
      notify_inactive: notify_inactive?
    ).call

    if result.recorded_count.zero?
      redirect_to record_training_path,
                  alert: 'No training events were recorded. Everyone selected was already trained ' \
                         'or could not be trained.'
      return
    end

    skipped_message = result.skipped_count.positive? ? " #{result.skipped_count} skipped." : ''
    event_label = 'event'.pluralize(result.recorded_count)
    redirect_to training_catalog_path,
                notice: "Recorded #{result.recorded_count} training #{event_label} " \
                        "for #{training_topic.name}.#{skipped_message}#{bulk_inactive_note(result)}"
  rescue ActiveRecord::RecordNotFound
    redirect_to record_training_path, alert: 'Training topic not found.'
  end

  def add_training
    unless can_train_topic?(@training_topic)
      redirect_to redirect_back_path, alert: "You don't have permission to train #{@training_topic.name}."
      return
    end

    # Check if training already exists
    existing = Training.find_by(trainee: @trainee, training_topic: @training_topic)
    if existing
      redirect_to redirect_back_path(user_id: @trainee.id),
                  notice: "#{@trainee.display_name} is already trained in #{@training_topic.name}."
      return
    end

    result = TrainingRecorder.new(
      current_user: true_user,
      training_topic: @training_topic,
      trainee_ids: [@trainee.id.to_s],
      trainer: true_user,
      trained_at: Time.current,
      notify_inactive: notify_inactive?
    ).call

    if result.recorded_count.positive?
      redirect_to redirect_back_path(user_id: @trainee.id),
                  notice: "#{@trainee.display_name} has been marked as trained in " \
                          "#{@training_topic.name}.#{single_inactive_note(result)}"
    elsif @trainee.banned?
      redirect_to redirect_back_path(user_id: @trainee.id),
                  alert: "#{@trainee.display_name} is banned and cannot be trained."
    else
      redirect_to redirect_back_path(user_id: @trainee.id),
                  alert: "Failed to add training for #{@trainee.display_name}."
    end
  end

  def remove_training
    unless can_revoke_topic_training?(@training_topic)
      redirect_to record_training_path, alert: "You don't have permission to remove #{@training_topic.name} training."
      return
    end

    trainings = Training.where(trainee: @trainee, training_topic: @training_topic)
    count = trainings.count

    if count.positive?
      trainings.destroy_all
      # Create journal entry for the trainee
      Journal.create!(
        user: @trainee,
        actor_user: true_user,
        action: 'training_removed',
        changes_json: {
          'training' => {
            'topic' => @training_topic.name,
            'removed_by' => true_user.display_name,
            'removed_at' => Time.current.iso8601
          }
        },
        changed_at: Time.current,
        highlight: true
      )
      redirect_to redirect_back_path(user_id: @trainee.id),
                  notice: "Removed #{@training_topic.name} training from #{@trainee.display_name}."
    else
      redirect_to redirect_back_path(user_id: @trainee.id),
                  alert: "#{@trainee.display_name} was not trained in #{@training_topic.name}."
    end
  end

  private

  # Directors who hold training.grant_trainer reach this page to appoint trainers even when
  # they train nothing themselves, so trainer capability alone is not the only way in.
  #
  # Who may act is decided by the account being viewed as, so impersonating a trainer shows
  # what that trainer can do. Impersonation is admin-only and lapses if the real account
  # stops being an administrator, so this can only ever narrow the session's authority.
  # Who is *recorded* as the trainer is a separate question — see
  # #selected_trainer_for_recording, which stays on the real account.
  def require_trainer_or_admin
    return if current_user_admin?
    return if current_user.trainer_capabilities.any?
    return if current_user.can_for_any_topic?(:'training.record')
    return if current_user.can?(:'training.grant_trainer')

    redirect_to root_path, alert: "You don't have permission to train members."
  end

  # The record-training UI asks the trainer whether an inactive member should hear about it;
  # absent an answer we record the training and stay quiet.
  def notify_inactive?
    ActiveModel::Type::Boolean.new.cast(params[:notify_inactive]) || false
  end

  def bulk_inactive_note(result)
    return '' unless result.inactive_count.to_i.positive?

    label = 'inactive member'.pluralize(result.inactive_count)
    state = notify_inactive? ? 'notified' : 'not notified'
    " #{result.inactive_count} #{label} trained and #{state}."
  end

  def single_inactive_note(result)
    return '' unless result.inactive_count.to_i.positive?

    if notify_inactive?
      ' Their membership is inactive; a training notification was sent anyway.'
    else
      ' Their membership is inactive, so no notification was sent.'
    end
  end

  def set_trainee
    @trainee = User.find(params[:user_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to record_training_path, alert: 'Member not found.'
  end

  def set_training_topic
    @training_topic = TrainingTopic.find(params[:topic_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to record_training_path, alert: 'Training topic not found.'
  end

  def trainable_topics_for_actor
    return TrainingTopic.order(:name) if current_user_admin?

    topic_ids = current_user.training_topics.ids |
                current_user.topics_with_privilege(:'training.record').ids
    TrainingTopic.where(id: topic_ids).order(:name)
  end

  def can_train_topic?(topic)
    return true if current_user_admin?

    current_user&.may_record_training?(topic) || false
  end

  # Deleting a training here takes away the topic's privileges, the same operation the topic
  # page calls revoking. Being allowed to record training is not that authority, so this asks
  # for training.revoke rather than reusing can_train_topic?.
  def can_revoke_topic_training?(topic)
    current_user&.may_revoke_training?(topic) || false
  end

  def prepare_record_training_form
    @trainable_topics = trainable_topics_for_actor
    @trainer_options = trainer_options_for_recording
    @recording_users = recording_user_options
    @initial_trainee_ids = initial_trainee_ids_from_params
    @initial_topic_id = params[:topic_id].presence
    return unless current_user_admin?

    @trainer_manage_user = User.find_by(id: params[:trainer_user_id]) if params[:trainer_user_id].present?
    @all_training_topics = TrainingTopic.order(:name)
    @users_for_search = User.ordered_by_display_name
  end

  def initial_trainee_ids_from_params
    if params[:trainee_ids].present?
      params[:trainee_ids].to_s.split(',').map(&:strip).compact_blank
    else
      Array(params[:member].presence || params[:user_id].presence).compact_blank.map(&:to_s)
    end
  end

  def trainer_options_for_recording
    # Which trainers may be picked follows the account being viewed as; who is recorded as
    # the trainer stays the real account, so a training is always named after whoever was
    # actually at the keyboard.
    return [true_user] unless current_user_admin?

    trainer_ids = TrainerCapability.distinct.pluck(:user_id)
    trainer_ids << true_user.id
    User.where(id: trainer_ids.uniq).ordered_by_display_name
  end

  def recording_user_options
    users = User.ordered_by_display_name.to_a
    user_ids = users.map(&:id)
    trained_topic_ids_by_user = Training.where(trainee_id: user_ids)
                                        .pluck(:trainee_id, :training_topic_id)
                                        .each_with_object(
                                          Hash.new { |hash, key| hash[key] = [] }
                                        ) do |(trainee_id, topic_id), grouped|
      grouped[trainee_id] << topic_id
    end
    can_train_topic_ids_by_user = TrainerCapability.where(user_id: user_ids)
                                                   .pluck(:user_id, :training_topic_id)
                                                   .each_with_object(
                                                     Hash.new { |hash, key| hash[key] = [] }
                                                   ) do |(user_id, topic_id), grouped|
      grouped[user_id] << topic_id
    end

    users.map do |user|
      {
        id: user.id,
        name: user.display_name,
        email: user.email,
        username: user.username,
        active: user.active?,
        banned: user.banned?,
        trained_topic_ids: trained_topic_ids_by_user[user.id],
        can_train_topic_ids: can_train_topic_ids_by_user[user.id]
      }
    end
  end

  def selected_trainer_for_recording
    return true_user unless current_user_admin?

    trainer_options_for_recording.find { |trainer| trainer.id.to_s == params[:trainer_id].to_s } || true_user
  end

  def parsed_trained_at
    Date.iso8601(params[:trained_at].presence || Date.current.iso8601).in_time_zone
  rescue ArgumentError
    Date.current.in_time_zone
  end

  def redirect_back_path(user_id: nil)
    if params[:return_to] == 'topic' && @training_topic
      edit_training_topic_path(@training_topic)
    elsif params[:return_to] == 'profile' && (user_id || @trainee)
      user_path(user_id || @trainee, anchor: 'training-access-section')
    elsif user_id
      record_training_path(user_id: user_id)
    else
      record_training_path
    end
  end
end
