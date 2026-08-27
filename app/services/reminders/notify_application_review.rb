module Reminders
  class NotifyApplicationReview
    def self.call(now: Time.current)
      new(now: now).call
    end

    def self.record_delivery!(application, at: Time.current)
      application.with_lock do
        application.update!(application_reminder_sent_at: at)
      end
    end

    def initialize(now:)
      @now = now
    end

    def call
      return unless ReminderSetting.enabled?('application_review')

      ApplicationReviewEligibility.due(now: @now).find_each do |application|
        notify_application(application)
      end
    end

    private

    def notify_application(application)
      application.with_lock do
        return unless ApplicationReviewEligibility.due?(application, now: @now)

        recipients = director_recipients
        return if recipients.empty?

        recipients.each do |staff|
          MemberMailer.staff_application_reminder(application, staff.email.to_s.strip).deliver_later
        end
        self.class.record_delivery!(application, at: @now)
      end
    rescue StandardError => e
      Rails.logger.error(
        "[NotifyApplicationReview] application_id=#{application&.id} #{e.class}: #{e.message}"
      )
    end

    def director_recipients
      recipients = []
      MembershipApplications::DirectorRecipients.find_each { |staff| recipients << staff }
      recipients
    end
  end
end
