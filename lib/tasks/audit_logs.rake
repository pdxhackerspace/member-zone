namespace :audit_logs do
  desc 'Run one audit log source now and store what it prints: audit_logs:run[SOURCE_NAME_OR_ID]'
  task :run, [:source] => :environment do |_task, args|
    source = AuditLogsTaskHelper.find_source(args[:source])
    run = AuditLogs::RunSource.call(source)
    puts "#{source.name}: #{run.status}, #{run.entries_added} new entries"
    puts run.output if run.output.present?
  end

  desc 'Run an audit log source and show what it would store, without storing it (dry run)'
  task :preview, [:source] => :environment do |_task, args|
    source = AuditLogsTaskHelper.find_source(args[:source])
    result = AuditLogs::ScriptRunner.call(source, since: source.last_entry_at)
    entries = AuditLogs::OutputParser.call(result.stdout)
    stored = source.audit_log_entries.where(fingerprint: entries.pluck(:fingerprint)).pluck(:fingerprint)

    puts "[DRY RUN] #{source.name}: exit #{result.exit_code.inspect}, #{entries.size} lines"
    entries.each do |entry|
      state = stored.include?(entry[:fingerprint]) ? 'stored' : 'new   '
      puts "  #{state}  #{entry[:occurred_at].iso8601}  #{entry[:message]}"
    end
    puts result.stderr if result.stderr.present?
  end

  desc 'Queue a run for every enabled source whose interval has elapsed (what the hourly job does)'
  task dispatch: :environment do
    AuditLogs::DispatchJob.perform_now
  end
end

module AuditLogsTaskHelper
  def self.find_source(identifier)
    abort 'Usage: rails audit_logs:run[SOURCE_NAME_OR_ID]' if identifier.blank?

    AuditLogSource.find_by(id: identifier.to_s[/\A\d+\z/]) || AuditLogSource.find_by!(name: identifier)
  end
end
