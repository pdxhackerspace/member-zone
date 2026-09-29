module AuditLogs
  # Runs one audit log source. The claim is a single conditional UPDATE, so two workers
  # handed the same source cannot both run it.
  class RunSourceJob < ApplicationJob
    queue_as :default

    def perform(source_id)
      source = AuditLogSource.find_by(id: source_id)
      return unless source&.enabled?
      return unless source.claim_run!

      RunSource.call(source)
    end
  end
end
