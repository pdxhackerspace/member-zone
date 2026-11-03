module Announcers
  # Queued by the access webhook for each entry, so the webhook answers the door controller
  # without waiting on announcer bookkeeping.
  class ArrivalJob < ApplicationJob
    queue_as :default

    def perform(access_log_id)
      access_log = AccessLog.find_by(id: access_log_id)
      ArrivalDispatcher.call(access_log) if access_log
    end
  end
end
