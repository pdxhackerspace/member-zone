module Reminders
  # Reminds members holding a blank device-issued parking permit to fill it in online. Each
  # reminder carries a fresh 12-hour link, so it is delivered directly rather than through the
  # mail queue, where review could outlast the link.
  class NotifyParkingPermitDetails
    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      return unless ParkingPermitDetailsEligibility.reminder_enabled?

      ParkingPermitDetailsEligibility.due(now: @now).each { |notice| notify(notice) }
    end

    private

    def notify(notice)
      notice.with_lock do
        return unless ParkingPermitDetailsEligibility.due?(notice, now: @now)

        link = ParkingPermitLink.issue_for_blank_permit!(notice, now: @now)
        MemberMailer.parking_permit_details_reminder(
          notice.user, **ParkingPermits::DeviceIssuer.link_mail_args(link), parking_notice_id: notice.id
        ).deliver_later
        ParkingPermitDetailsEligibility.record_delivery!(notice, at: @now)
      end
    rescue StandardError => e
      Rails.logger.error("[NotifyParkingPermitDetails] notice_id=#{notice.id} failed: #{e.class}: #{e.message}")
    end
  end
end
