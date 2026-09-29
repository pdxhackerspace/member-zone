require Rails.root.join('lib/audit_log_entry_guard')

# Enforces audit log immutability in the database as well as the model: no deletes, no
# truncates, and no edits to anything but the explanation and alert columns.
class GuardAuditLogEntries < ActiveRecord::Migration[8.1]
  def up
    execute AuditLogEntryGuard::UP
  end

  def down
    execute AuditLogEntryGuard::DOWN
  end
end
