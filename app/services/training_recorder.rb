class TrainingRecorder
  Result = Struct.new(:recorded_count, :skipped_count, :permitted, :inactive_count)

  # rubocop:disable Metrics/ParameterLists -- keyword arguments, one per recorded field
  def initialize(current_user:, training_topic:, trainee_ids:, trainer:, trained_at:, notify_inactive: false)
    # rubocop:enable Metrics/ParameterLists
    @current_user = current_user
    @training_topic = training_topic
    @trainee_ids = trainee_ids
    @trainer = trainer
    @trained_at = trained_at
    @notify_inactive = notify_inactive
  end

  # Recording training confers the topic's trained_in roles, so the actor must already
  # hold every global privilege it would hand over. Callers should check this first so
  # they can report the refusal; the guard in #call is a backstop.
  def permitted?
    return true if current_user.nil?

    current_user.may_confer?(training_topic, member_sources: %w[trained_in])
  end

  def call
    return Result.new(0, trainee_ids.size, false, 0) unless permitted?

    trainees = User.where(id: trainee_ids).index_by { |user| user.id.to_s }
    @recorded_count = 0
    @inactive_count = 0
    @skipped_count = trainee_ids.count { |id| trainees[id].nil? }

    trainee_ids.each do |trainee_id|
      trainee = trainees[trainee_id]
      next unless trainee

      training_skip_reason(trainee) ? @skipped_count += 1 : record_for(trainee)
    end

    Result.new(@recorded_count, @skipped_count, true, @inactive_count)
  end

  private

  attr_reader :current_user, :training_topic, :trainee_ids, :trainer, :trained_at, :notify_inactive

  def record_for(trainee)
    training = Training.create!(
      trainee: trainee,
      trainer: trainer,
      training_topic: training_topic,
      trained_at: trained_at
    )
    record_training_journal(trainee, training.trained_at)
    enqueue_training_completed_mail(trainee)
    @recorded_count += 1
    @inactive_count += 1 unless trainee.active?
  end

  # Inactive members are still trainable — a lapsed membership says nothing about whether
  # someone sat through a class. Banned members are a deliberate exception.
  def training_skip_reason(trainee)
    return :already_trained if Training.exists?(trainee: trainee, training_topic: training_topic)
    return :banned if trainee.banned?

    nil
  end

  def record_training_journal(trainee, actual_trained_at)
    Journal.create!(
      user: trainee,
      actor_user: current_user,
      action: 'training_added',
      changes_json: {
        'training' => {
          'topic' => training_topic.name,
          'trainer' => trainer&.display_name || 'Unknown',
          'trained_at' => actual_trained_at.iso8601
        }
      },
      changed_at: Time.current,
      highlight: true
    )
  end

  # An inactive member gets the "you were trained" mail only when the trainer said so,
  # since it otherwise reads as a welcome to a space they currently cannot enter.
  def enqueue_training_completed_mail(trainee)
    return if trainee.email.blank?
    return if !trainee.active? && !notify_inactive

    QueuedMail.enqueue(:training_completed, trainee,
                       reason: "Trained in #{training_topic.name}",
                       training_topic: training_topic.name)
  end
end
