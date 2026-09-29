require Rails.root.join('lib/audit_log_entry_guard')

# schema.rb has no way to express triggers, so a dump would silently drop the guard on
# audit_log_entries and a database built from it (every test run) would be unprotected.
# Appending the statement to the dump keeps `db:schema:load` and `db:migrate` in agreement.
module SchemaDumperGuard
  def trailer(stream)
    stream.puts AuditLogEntryGuard.schema_statement if @connection.adapter_name.match?(/postg/i)
    stream.puts
    super
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::SchemaDumper.prepend(SchemaDumperGuard)
end
