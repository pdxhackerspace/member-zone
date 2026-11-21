class DirectMessage
  # Saves a message and emails it the same way the messages page does. Returns the message
  # either way, so a caller can read validation errors when it did not save. A recipient
  # with no address still gets the in-app message; pass email: true to attempt delivery anyway.
  def self.deliver(sender:, recipient:, subject:, body:, email: recipient.email.present?)
    message = sender.sent_messages.build(recipient: recipient, subject: subject, body: body)
    return message unless message.save

    MemberMailer.message_received(message).deliver_later if email
    message
  end
end
