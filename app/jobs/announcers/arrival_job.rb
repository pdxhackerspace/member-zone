module Announcers
  # Queued by the access webhook for each arrival, so the webhook answers the door controller
  # without waiting. Announcements and the parking arrival reminder both start here, and a
  # failure in one does not stop the other.
  class ArrivalJob < ApplicationJob
    queue_as :default

    def perform(access_log_id)
      access_log = AccessLog.find_by(id: access_log_id)
      return unless access_log

      run(ArrivalDispatcher, access_log)
      run(Reminders::NotifyParkingArrival, access_log)
    end

    private

    def run(handler, access_log)
      handler.call(access_log)
    rescue StandardError => e
      ErrorReporting.report(e, context: { access_log_id: access_log.id, handler: handler.name }, severity: :warning)
    end
  end
end
