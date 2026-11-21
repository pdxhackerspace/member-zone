class TrainingAttributionNotifier
  # An admin recording a class someone else taught tells that trainer, and the topic's other
  # active trainers, through the same direct message a copied training-request reply uses.
  # Naming yourself sends nothing: the person who entered it already knows.
  def initialize(training:, actor:, except: [])
    @training = training
    @actor = actor
    # People granted this topic during the same action are not its trainers yet, so a batch
    # appointment must not tell them about the classmates appointed beside them.
    @except = Array(except)
  end

  def call
    return if training.nil?
    return unless actor&.admin?
    return if training.trainer_id.blank? || training.trainer_id == actor.id

    recipients.each { |recipient| deliver(recipient) }
  end

  private

  attr_reader :training, :actor, :except

  def recipients
    named = training.trainer
    others = training.training_topic.notifiable_trainers(except: [actor, training.trainee, named, *except])
    people = [actor.id, training.trainee_id].include?(named.id) ? [] : [named]
    people + others.to_a
  end

  def deliver(recipient)
    DirectMessage.deliver(sender: actor, recipient: recipient, subject: subject, body: body_for(recipient))
  end

  def subject
    "Training recorded: #{training.trainee.display_name} in #{training.training_topic.name}"
  end

  def body_for(recipient)
    lead = "#{actor.display_name} recorded #{training.trainee.display_name} as trained in " \
           "#{training.training_topic.name} on #{training.trained_at.to_date.to_fs(:long)}"
    return "#{lead} and named you as the trainer." if recipient.id == training.trainer_id

    "#{lead} by #{training.trainer.display_name}."
  end
end
