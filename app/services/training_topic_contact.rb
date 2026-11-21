# One message to everyone a viewer may contact about a topic. Each recipient gets their
# own Message, so a reply comes back to the sender the same way any other message does.
class TrainingTopicContact
  Result = Struct.new(:sent_count, :error, keyword_init: true)

  MAX_SUBJECT = 200
  MAX_BODY = 5_000

  def initialize(topic:, viewer:, sender:, subject:, body:)
    @roster = TrainingTopicRoster.new(topic: topic, viewer: viewer)
    @sender = sender
    @subject = subject.to_s.strip
    @body = body.to_s.strip
  end

  def deliver
    error = refusal
    return failure(error) if error

    sent = recipients.count { |recipient| deliver_one(recipient).persisted? }
    return failure('The message could not be sent.') if sent.zero?

    Result.new(sent_count: sent, error: nil)
  end

  private

  def refusal
    return 'You cannot contact the members trained in this topic.' unless @roster.contactable?
    return 'A subject and a message are both required.' if @subject.blank? || @body.blank?
    return 'That message is too long.' if @subject.length > MAX_SUBJECT || @body.length > MAX_BODY
    return 'There is nobody to contact for this topic.' if recipients.empty?

    nil
  end

  def recipients
    @recipients ||= @roster.recipients(except: @sender).to_a
  end

  def deliver_one(recipient)
    DirectMessage.deliver(sender: @sender, recipient: recipient, subject: @subject, body: @body)
  end

  def failure(error)
    Result.new(sent_count: 0, error: error)
  end
end
