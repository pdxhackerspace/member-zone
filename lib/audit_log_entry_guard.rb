# Database-level guard for audit_log_entries: rows cannot be deleted or truncated, and the
# columns that make up the record itself cannot change. Only the explanation, the alert
# bookkeeping and explained_by (which the FK nulls when a user is deleted) may be updated.
#
# db/schema.rb cannot represent triggers, so the SQL lives here as the single source of truth:
# the migration runs it, and config/initializers/schema_dumper_guard.rb appends it to every
# schema dump, which is what keeps `db:schema:load` (and so the test database) guarded too.
module AuditLogEntryGuard
  LOCKED_COLUMNS = %w[audit_log_source_id occurred_at message raw fingerprint created_at].freeze

  # Kept multi-line: it is written into schema.rb verbatim.
  # rubocop:disable-next Rails/SquishedSQLHeredocs
  UP = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION audit_log_entries_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF (#{LOCKED_COLUMNS.map { |c| "NEW.#{c}" }.join(', ')})
           IS DISTINCT FROM (#{LOCKED_COLUMNS.map { |c| "OLD.#{c}" }.join(', ')}) THEN
          RAISE EXCEPTION 'audit_log_entries rows cannot be edited; only the explanation and alert columns may change';
        END IF;
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'audit_log_entries rows cannot be deleted';
    END;
    $$ LANGUAGE plpgsql;

    DROP TRIGGER IF EXISTS audit_log_entries_guard_rows ON audit_log_entries;
    CREATE TRIGGER audit_log_entries_guard_rows BEFORE UPDATE OR DELETE ON audit_log_entries
      FOR EACH ROW EXECUTE FUNCTION audit_log_entries_guard();

    DROP TRIGGER IF EXISTS audit_log_entries_guard_truncate ON audit_log_entries;
    CREATE TRIGGER audit_log_entries_guard_truncate BEFORE TRUNCATE ON audit_log_entries
      FOR EACH STATEMENT EXECUTE FUNCTION audit_log_entries_guard();
  SQL

  # rubocop:disable-next Rails/SquishedSQLHeredocs
  DOWN = <<~SQL.freeze
    DROP TRIGGER IF EXISTS audit_log_entries_guard_rows ON audit_log_entries;
    DROP TRIGGER IF EXISTS audit_log_entries_guard_truncate ON audit_log_entries;
    DROP FUNCTION IF EXISTS audit_log_entries_guard();
  SQL

  # The statement appended to db/schema.rb.
  def self.schema_statement
    "  execute <<~'SQL'\n#{UP.lines.map { |line| line.strip.empty? ? line : "    #{line}" }.join}  SQL\n"
  end
end
