module QueuedMailApplicationLinkReminders
  extend ActiveSupport::Concern

  class_methods do
    def enqueue_application_link_reminder(verification, reason: nil, **extra_args)
      dest = verification.email
      return nil if dest.blank?

      recipient = verification_recipient_for(verification)
      action = 'application_link_reminder'
      merged_args = extra_args.merge(application_verification_id: verification.id)
      template = EmailTemplate.find_enabled(action)
      variables = MemberMailer.build_template_variables(recipient, merged_args)
      if !MailRecipientGuard.blocked_email?(dest) && template&.send_immediately?
        return deliver_immediately(template, dest, variables)
      end

      attrs = queued_mail_attrs(dest, reason || 'Application link reminder', nil, action, merged_args)
      record = if template
                 create_queued_mail_from_template(template, variables, attrs)
               else
                 create_queued_mail_from_message(
                   MemberMailer.application_link_reminder(recipient, **merged_args), attrs
                 )
               end
      MailLogEntry.log!(record, 'created', details: "Queued application link reminder to #{dest}")
      MailRecipientGuard.block_delivery_to!(record)
      record
    end

    def verification_recipient_for(verification)
      QueuedMail::ApplicantMailRecipient.new(
        display_name: verification.email.split('@').first.presence || 'Applicant',
        email: verification.email,
        username: 'Not set'
      )
    end
  end
end
