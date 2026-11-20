class TrainingRequestResponder
  Result = Struct.new(:success, :error, :notice, keyword_init: true)

  # Active trainers for the topic, aside from the person writing the reply and the member
  # who already receives it. Inactive trainers are left out, matching the original request.
  def self.other_trainers(request, sender:)
    request.training_topic.trainers.active
           .where.not(id: [sender.id, request.user_id])
           .order(:full_name, :id)
  end

  def initialize(request:, sender:, body:, notify_other_trainers:)
    @request = request
    @sender = sender
    @body = body
    @notify_other_trainers = notify_other_trainers
  end

  def call
    message = member_message
    return failure(message) unless message.save

    deliver(message)
    copied = copy_to_other_trainers
    request.respond!(sender)
    Result.new(success: true, error: nil, notice: notice_for(copied))
  end

  private

  attr_reader :request, :sender, :body, :notify_other_trainers

  def member_message
    build_message(
      recipient: request.user,
      subject: "Training request response: #{request.training_topic.name}",
      body: body
    )
  end

  def failure(message)
    Result.new(success: false, error: message.errors.full_messages.to_sentence, notice: nil)
  end

  def copy_to_other_trainers
    return 0 unless notify_other_trainers

    copied = 0
    self.class.other_trainers(request, sender: sender).each do |trainer|
      copied += 1 if deliver_copy(trainer)
    end
    copied
  end

  def deliver_copy(trainer)
    message = build_message(recipient: trainer, subject: copy_subject, body: copy_body)
    return false unless message.save

    deliver(message) if trainer.email.present?
    true
  end

  def copy_subject
    "Training request response to #{request.user.display_name}: #{request.training_topic.name}"
  end

  def copy_body
    "Copy of the response sent to #{request.user.display_name}:\n\n#{body}"
  end

  def build_message(recipient:, subject:, body:)
    sender.sent_messages.build(recipient: recipient, subject: subject, body: body)
  end

  def deliver(message)
    MemberMailer.message_received(message).deliver_later
  end

  def notice_for(copied)
    return 'Response sent to member and the other trainers.' if copied.positive?

    'Response sent to member.'
  end
end
