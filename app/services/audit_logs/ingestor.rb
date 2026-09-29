module AuditLogs
  # Stores parsed entries, skipping any the source has already recorded, and returns the
  # ones that were new. Only new entries go on to be checked against alert rules, so a
  # program that re-prints old lines never re-alerts.
  class Ingestor
    BATCH_SIZE = 1000

    def self.call(source, entries)
      new(source, entries).call
    end

    def initialize(source, entries)
      @source = source
      @entries = entries
    end

    def call
      ids = @entries.each_slice(BATCH_SIZE).flat_map { |batch| insert(batch) }
      return AuditLogEntry.none if ids.empty?

      AuditLogEntry.where(id: ids).order(:occurred_at, :id)
    end

    private

    def insert(batch)
      rows = batch.map { |entry| entry.merge(audit_log_source_id: @source.id) }
      AuditLogEntry.insert_all(
        rows, unique_by: %i[audit_log_source_id fingerprint], returning: %w[id]
      ).rows.flatten
    end
  end
end
