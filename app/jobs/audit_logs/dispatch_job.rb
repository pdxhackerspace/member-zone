module AuditLogs
  # Wakes hourly and queues a run for every enabled source whose interval has elapsed.
  class DispatchJob < ApplicationJob
    queue_as :default

    def perform
      AuditLogSource.enabled.find_each do |source|
        RunSourceJob.perform_later(source.id) if source.due?
      end
    end
  end
end
