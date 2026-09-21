# frozen_string_literal: true

module MembershipApplications
  # Reminds executive application reviewers about applications that have been waiting.
  #
  # How long an application may sit before the first reminder, and the gap between reminders
  # after that, come from the staff_application reminder's settings row like every other
  # reminder's cadence. It ships enabled: a review queue nobody is told about is the problem it
  # exists to prevent.
  class NotifyDirectorsOfStaleApplications
    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      return unless Reminders::StaleApplicationEligibility.reminder_enabled?

      Reminders::StaleApplicationEligibility.due(now: @now).find_each do |application|
        notify_application(application)
      end
    end

    private

    def notify_application(application)
      application.with_lock do
        return unless Reminders::StaleApplicationEligibility.due?(application, now: @now)

        recipients = director_recipients
        return if recipients.empty?

        recipients.each do |staff|
          MemberMailer.staff_application_reminder(application, staff.email.to_s.strip).deliver_later
        end
        Reminders::StaleApplicationEligibility.record_delivery!(application, at: @now)
      end
    rescue StandardError => e
      Rails.logger.error(
        "[NotifyDirectorsOfStaleApplications] application_id=#{application&.id} #{e.class}: #{e.message}"
      )
    end

    def director_recipients
      recipients = []
      DirectorRecipients.find_each { |staff| recipients << staff }
      recipients
    end
  end
end
