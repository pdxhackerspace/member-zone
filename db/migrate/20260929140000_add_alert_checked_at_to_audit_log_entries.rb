# Marks the entries whose alert rules have been checked and their emails handed off, so an
# alert that failed to send is retried on the next run instead of being lost. Existing entries
# were all checked by the previous code, so they are marked to avoid a flood of old alerts.
class AddAlertCheckedAtToAuditLogEntries < ActiveRecord::Migration[8.1]
  def up
    add_column :audit_log_entries, :alert_checked_at, :datetime
    execute 'UPDATE audit_log_entries SET alert_checked_at = created_at'
    add_index :audit_log_entries, :audit_log_source_id, where: 'alert_checked_at IS NULL',
                                                        name: 'index_audit_log_entries_unchecked'
  end

  def down
    remove_index :audit_log_entries, name: 'index_audit_log_entries_unchecked'
    remove_column :audit_log_entries, :alert_checked_at
  end
end
