module Reminders
  # Emails a member who just arrived about the parking they still have open.
  #
  # Called from the arrival job for every fresh scan at an outside door, whether or not
  # the member asked to be announced. The check and the send record share a lock on the
  # member, so two scans a second apart send one email. Mail goes straight out: an arrival
  # reminder that waited for review would be about a visit that was already over.
  class NotifyParkingArrival
    def self.call(access_log, now: Time.current)
      new(access_log, now).call
    end

    def initialize(access_log, now)
      @access_log = access_log
      @user = access_log&.user
      @now = now
    end

    def call
      return if @access_log.nil?

      reason = ParkingArrivalEligibility.skip_reason(@user, access_log: @access_log, now: @now)
      return log_skip(reason) if reason

      @user.with_lock { deliver_if_still_due }
    end

    private

    def deliver_if_still_due
      reason = ParkingArrivalEligibility.skip_reason(@user, access_log: @access_log, now: @now)
      return log_skip(reason) if reason

      notices = ParkingArrivalEligibility.notices_for(@user, now: @now)
      MemberMailer.parking_arrival_reminder(@user, ParkingArrivalMessage.call(@user, notices)).deliver_later
      ParkingArrivalEligibility.record_delivery!(@user, at: @now)
      log("sent #{notices.size} #{'notice'.pluralize(notices.size)}")
    rescue StandardError => e
      Rails.logger.error("[NotifyParkingArrival] user_id=#{@user&.id} failed: #{e.class}: #{e.message}")
      nil
    end

    # Most scans have nothing to say. Those stay at debug so a busy door does not fill the log;
    # a reminder that was held back is the one an admin goes looking for.
    def log_skip(reason)
      Rails.logger.public_send(quiet?(reason) ? :debug : :info) { log_line(reason) }
      nil
    end

    def quiet?(reason)
      reason.in?(['reminder is disabled', 'no open notice to mention', 'no member matched the entry',
                  'entry is not an arrival', 'no access log']) || reason.start_with?('entry is older than')
    end

    def log(message)
      Rails.logger.info(log_line(message))
    end

    def log_line(message)
      "Parking arrival: access log #{@access_log.id} (#{@user&.username}): #{message}"
    end
  end
end
