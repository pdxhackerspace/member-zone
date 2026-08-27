module QueuedMailApplicationLinkReminders
  extend ActiveSupport::Concern

  def self.suppress_application_link_reminder?(dest)
    return false unless Notifications::DeliveryGate.blocked?(mailer_action: 'application_link_reminder', email: dest)

    Rails.logger.info("[QueuedMail] Suppressed application_link_reminder to #{dest}: notification opt-out")
    true
  end

  class_methods do
    def enqueue_application_link_reminder(verification, reason: nil, **extra_args)
      dest = verification.email
      return nil if dest.blank?
      return nil if QueuedMailApplicationLinkReminders.suppress_application_link_reminder?(dest)

      QueuedMail::ApplicationLinkReminderEnqueue.call(verification, reason:, extra_args:)
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
