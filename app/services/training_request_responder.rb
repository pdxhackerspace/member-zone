class TrainingRequestResponder
  Result = Struct.new(:success, :error, :notice, keyword_init: true)

  # Active trainers for the topic, aside from the person writing the reply and the member
  # who already receives it.
  def self.other_trainers(request, sender:)
    request.training_topic.notifiable_trainers(except: [sender, request.user])
  end

  def initialize(request:, sender:, body:, notify_other_trainers:)
    @request = request
    @sender = sender
    @body = body
    @notify_other_trainers = notify_other_trainers
  end

  def call
    message = deliver_to_member
    return failure(message) unless message.persisted?

    copied = copy_to_other_trainers
    request.respond!(sender)
    Result.new(success: true, error: nil, notice: notice_for(copied))
  end

  private

  attr_reader :request, :sender, :body, :notify_other_trainers

  def deliver_to_member
    DirectMessage.deliver(
      sender: sender,
      recipient: request.user,
      subject: "Training request response: #{request.training_topic.name}",
      body: body,
      email: true
    )
  end

  def failure(message)
    Result.new(success: false, error: message.errors.full_messages.to_sentence, notice: nil)
  end

  def copy_to_other_trainers
    return 0 unless notify_other_trainers

    self.class.other_trainers(request, sender: sender).count { |trainer| deliver_copy(trainer).persisted? }
  end

  def deliver_copy(trainer)
    DirectMessage.deliver(sender: sender, recipient: trainer, subject: copy_subject, body: copy_body)
  end

  def copy_subject
    "Training request response to #{request.user.display_name}: #{request.training_topic.name}"
  end

  def copy_body
    "Copy of the response sent to #{request.user.display_name}:\n\n#{body}"
  end

  def notice_for(copied)
    return 'Response sent to member and the other trainers.' if copied.positive?

    'Response sent to member.'
  end
end
