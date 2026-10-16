class TrainerAppointer
  Result = Struct.new(:appointed_count, :trained_count, :skipped_count, :inactive_count)

  # A trainer has to hold the topic themselves, so appointing someone who was never
  # recorded as trained records that training too, dated and attributed like any other.
  #
  # rubocop:disable Metrics/ParameterLists -- keyword arguments, one per recorded field
  def initialize(current_user:, training_topic:, trainee_ids:, trainer:, trained_at:, notify_inactive: false)
    # rubocop:enable Metrics/ParameterLists
    @current_user = current_user
    @training_topic = training_topic
    @trainee_ids = trainee_ids.map(&:to_s)
    @trainer = trainer
    @trained_at = trained_at
    @notify_inactive = notify_inactive
  end

  def call
    trainees = User.where(id: trainee_ids).index_by { |user| user.id.to_s }
    result = Result.new(0, 0, trainee_ids.count { |id| trainees[id].nil? }, 0)

    trainee_ids.each do |trainee_id|
      trainee = trainees[trainee_id]
      next unless trainee

      skip?(trainee) ? result.skipped_count += 1 : appoint(trainee, result)
    end

    result
  end

  private

  attr_reader :current_user, :training_topic, :trainee_ids, :trainer, :trained_at, :notify_inactive

  def skip?(trainee)
    trainee.banned? || TrainerCapability.exists?(user: trainee, training_topic: training_topic)
  end

  def appoint(trainee, result)
    ActiveRecord::Base.transaction do
      result.trained_count += 1 if record_missing_training(trainee)
      TrainerCapability.create!(user: trainee, training_topic: training_topic)
      log_capability_added(trainee)
    end
    notify(trainee)
    result.appointed_count += 1
    result.inactive_count += 1 unless trainee.active?
  end

  def record_missing_training(trainee)
    return false if Training.exists?(trainee: trainee, training_topic: training_topic)

    training = Training.create!(trainee: trainee, trainer: trainer, training_topic: training_topic,
                                trained_at: trained_at)
    log(trainee, 'training_added', 'training' => {
          'topic' => training_topic.name,
          'trainer' => trainer&.display_name || 'Unknown',
          'trained_at' => training.trained_at.iso8601
        })
    true
  end

  def log_capability_added(trainee)
    log(trainee, 'trainer_capability_added', 'trainer_capability' => {
          'topic' => training_topic.name,
          'granted_by' => current_user&.display_name,
          'granted_at' => Time.current.iso8601
        })
  end

  def log(trainee, action, changes)
    Journal.create!(user: trainee, actor_user: current_user, action: action, changes_json: changes,
                    changed_at: Time.current, highlight: true)
  end

  # Same rule as recording training: an inactive member hears about it only when the
  # person recording it said so.
  def notify(trainee)
    return if trainee.email.blank?
    return if !trainee.active? && !notify_inactive

    QueuedMail.enqueue(:trainer_capability_granted, trainee,
                       reason: "Can now train #{training_topic.name}",
                       training_topic: training_topic.name)
  end
end
