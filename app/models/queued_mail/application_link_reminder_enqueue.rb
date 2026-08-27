class QueuedMail
  class ApplicationLinkReminderEnqueue
    def self.call(verification, reason:, extra_args:)
      new(verification, reason:, extra_args:).call
    end

    def initialize(verification, reason:, extra_args:)
      @verification = verification
      @dest = verification.email
      @reason = reason
      @extra_args = extra_args
    end

    def call
      recipient = QueuedMail.verification_recipient_for(@verification)
      action = 'application_link_reminder'
      merged_args = @extra_args.merge(
        application_verification_id: @verification.id,
        verification_token: @verification.token
      )
      template = EmailTemplate.find_enabled(action)
      variables = MemberMailer.build_template_variables(recipient, merged_args)
      return deliver_immediately(template, variables, merged_args) if send_immediately?(template)

      create_queued_mail(recipient, action, merged_args, template, variables)
    end

    private

    def send_immediately?(template)
      !MailRecipientGuard.blocked_email?(@dest) && template&.send_immediately?
    end

    def deliver_immediately(template, variables, merged_args)
      QueuedMail.deliver_immediately(
        template,
        @dest,
        variables,
        mailer_action: 'application_link_reminder',
        verification_token: merged_args[:verification_token]
      )
    end

    def create_queued_mail(recipient, action, merged_args, template, variables)
      attrs = QueuedMail.queued_mail_attrs(@dest, @reason || 'Application link reminder', nil, action, merged_args)
      record = if template
                 QueuedMail.create_queued_mail_from_template(template, variables, attrs)
               else
                 QueuedMail.create_queued_mail_from_message(
                   MemberMailer.application_link_reminder(recipient, **merged_args), attrs
                 )
               end
      MailLogEntry.log!(record, 'created', details: "Queued application link reminder to #{@dest}")
      MailRecipientGuard.block_delivery_to!(record)
      record
    end
  end
end
