class TrainingRequestsController < AuthenticatedController
  before_action :set_training_request, only: %i[edit update mark_trained dismiss]
  before_action :authorize_responder!, only: %i[edit update mark_trained]
  before_action :require_conferral_for_mark_trained!, only: %i[mark_trained]
  before_action :authorize_requester!, only: %i[dismiss]

  def new
    @member_requestable_topics = TrainingTopic.available_for_member_requests
  end

  def edit
    @requester = @training_request.user
  end

  def create
    topic = TrainingTopic.available_for_member_requests.find_by(id: training_request_params[:training_topic_id])
    if topic.nil?
      redirect_to new_training_request_path, alert: 'Please select a valid training topic.'
      return
    end

    share_contact = training_request_params[:share_contact_info] == '1'

    request = current_user.training_requests.build(
      training_topic: topic,
      share_contact_info: share_contact
    )

    if request.save
      queue_training_request_emails!(request)
      redirect_to user_path(current_user, tab: :profile),
                  notice: "Your training request for #{topic.name} has been sent."
    else
      redirect_to new_training_request_path, alert: request.errors.full_messages.to_sentence
    end
  end

  def update
    body = params[:training_request][:response_body].to_s.strip
    if body.blank?
      redirect_to edit_training_request_path(@training_request), alert: 'Response message cannot be blank.'
      return
    end

    # Authority to answer came from the real account, so the reply is signed by it too. An
    # impersonating session that used current_user here would post the member being viewed as
    # the author of an answer to a queue they may have no part in.
    message = true_user.sent_messages.build(
      recipient: @training_request.user,
      subject: "Training request response: #{@training_request.training_topic.name}",
      body: body
    )

    if message.save
      MemberMailer.message_received(message).deliver_later
      @training_request.respond!(true_user)
      redirect_to user_path(current_user), notice: 'Response sent to member.'
    else
      redirect_to edit_training_request_path(@training_request), alert: message.errors.full_messages.to_sentence
    end
  end

  # Trainer (or admin) records the training directly from the request. Recording a Training
  # marks the pending request(s) responded, so it disappears from every trainer's queue and
  # surfaces a "training completed" notification for the member.
  def mark_trained
    topic = @training_request.training_topic
    trainee = @training_request.user

    # Closing the request here has to name the same account the recording branch does, which
    # Training#clear_pending_training_requests takes from the trainer.
    if Training.exists?(trainee: trainee, training_topic: topic)
      @training_request.respond!(true_user) if @training_request.pending?
      redirect_back_or_to user_path(current_user),
                          notice: "#{trainee.display_name} is already trained in #{topic.name}."
      return
    end

    result = TrainingRecorder.new(
      current_user: true_user,
      training_topic: topic,
      trainee_ids: [trainee.id.to_s],
      trainer: true_user,
      trained_at: Time.current,
      # The member asked for this training, so they hear about it even if their membership lapsed.
      notify_inactive: true
    ).call

    if result.recorded_count.positive?
      redirect_back_or_to user_path(current_user),
                          notice: "Recorded training for #{trainee.display_name} in #{topic.name}."
    else
      redirect_back_or_to user_path(current_user),
                          alert: "Could not record training for #{trainee.display_name}."
    end
  end

  # Member dismisses a completed training request so it stops showing on their dashboard.
  def dismiss
    @training_request.dismiss!
    redirect_back_or_to user_path(current_user, tab: :training_history),
                        notice: 'Training update dismissed.'
  end

  private

  def set_training_request
    @training_request = TrainingRequest.find(params[:id])
  end

  def authorize_responder!
    return if current_user_admin?
    return if responder_for_request?

    redirect_to user_path(current_user), alert: 'You are not allowed to respond to that request.'
  end

  # Asks the real signed-in account, not the impersonated one, so a session viewing as a
  # trainer cannot answer that trainer's queue.
  def responder_for_request?
    return false unless @training_request.pending?

    topic_id = @training_request.training_topic_id
    current_user.training_topics.exists?(id: topic_id) ||
      current_user.can?(:'training.respond_requests', topic: topic_id)
  end

  # Recording training from a request confers the topic's privileges, so the no-escalation
  # rule applies here just as it does in the training controller. Replying does not confer
  # anything, so edit and update are left alone.
  def require_conferral_for_mark_trained!
    return if current_user.may_confer?(@training_request.training_topic, member_sources: %w[trained_in])

    redirect_to user_path(current_user),
                alert: 'You cannot record training that would grant privileges you do not hold.'
  end

  def authorize_requester!
    return if @training_request.user_id == current_user.id

    redirect_to user_path(current_user), alert: 'You are not allowed to update that request.'
  end

  def training_request_params
    params.expect(training_request: %i[training_topic_id share_contact_info])
  end

  def queue_training_request_emails!(request)
    topic = request.training_topic
    requester = request.user
    active_trainers = topic.trainers.active.order(:full_name, :id).to_a
    trainer_names = active_trainers.map(&:display_name).join(', ')
    requester_args = training_request_mail_args(request, recipient_role: 'member', trainer_names: trainer_names)

    QueuedMail.enqueue(
      :training_requested,
      requester,
      reason: "Training requested for #{topic.name}",
      **requester_args
    )

    active_trainers.each do |trainer|
      enqueue_trainer_training_request_mail(request, trainer, trainer_names: trainer_names)
    end
  end

  def training_request_mail_args(request, recipient_role:, trainer_names:)
    contact = MemberMailer.training_request_contact_fields(
      user: request.user,
      share_contact_info: request.share_contact_info
    )

    {
      training_topic: request.training_topic.name,
      requester_name: request.user.display_name,
      share_contact_info: request.share_contact_info,
      recipient_role: recipient_role,
      trainer_names: trainer_names,
      **contact
    }
  end

  def enqueue_trainer_training_request_mail(request, trainer, trainer_names:)
    return if trainer.email.blank?

    QueuedMail.enqueue(
      :training_requested,
      trainer,
      to: trainer.email,
      reason: "Training request notification for #{request.training_topic.name}",
      **training_request_mail_args(request, recipient_role: 'trainer', trainer_names: trainer_names)
    )
  end
end
