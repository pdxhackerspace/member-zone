module Reminders
  # Maps a reminder key to the service that knows its cadence, and traces a sent email back to
  # the sequence it belongs to.
  #
  # The tracing matters because a reminder can leave by two routes. The daily run enqueues mail
  # and records the send itself when the mail goes straight out; mail held for review leaves
  # days later from the mail queue, and that send has to land against the same sequence.
  class Registry
    def self.eligibility_for(reminder_key)
      {
        'slack_signup' => SlackSignupEligibility,
        'application_link' => ApplicationLinkEligibility,
        'payment_overdue' => PaymentOverdueEligibility,
        'orientation' => OrientationEligibility,
        'parking_notices' => ParkingNoticeEligibility,
        'lapsed_access' => LapsedAccessEligibility,
        'staff_application' => StaleApplicationEligibility
      }[reminder_key.to_s]
    end

    def self.for_mailer_action(action)
      eligibility_for(ReminderSetting.key_for_mailer_action(action))
    end

    # The subject a reminder email was about, which is not always its recipient: parking
    # reminders are about a notice and application link reminders about a verification, both
    # of which ride along in the queued mail's arguments.
    def self.subject_for(reminder_key, recipient:, mailer_args: nil)
      args = mailer_args.is_a?(Hash) ? mailer_args : {}

      case reminder_key.to_s
      when 'parking_notices' then ParkingNotice.find_by(id: args['parking_notice_id'])
      when 'application_link' then ApplicationVerification.find_by(id: args['application_verification_id'])
      else recipient
      end
    end
  end
end
