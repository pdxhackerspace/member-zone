module Reminders
  class NotifyApplicationLink
    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      return unless ApplicationLinkEligibility.active?

      ApplicationLinkEligibility.due(now: @now).find_each { |verification| notify_verification(verification) }
    end

    private

    def notify_verification(verification)
      verification.with_lock do
        return unless ApplicationLinkEligibility.due?(verification, now: @now)

        extras = MemberMailer.application_link_template_extras(verification)
        result = deliver_reminder_mail(verification, extras)
        return if result.nil?

        # Mail held for review has not reached the applicant yet, so the clock on the next
        # reminder only starts once something actually went out.
        return unless result.is_a?(QueuedMail::ImmediateDelivery)

        ApplicationLinkEligibility.record_delivery!(verification, at: @now)
      end
    end

    def deliver_reminder_mail(verification, extras)
      QueuedMail.enqueue_application_link_reminder(verification, reason: 'Application link reminder', **extras)
    rescue StandardError => e
      Rails.logger.error(
        "[NotifyApplicationLink] verification_id=#{verification.id} delivery failed: #{e.class}: #{e.message}"
      )
      nil
    end
  end
end
