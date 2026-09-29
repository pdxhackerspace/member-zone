require 'test_helper'

class AuditLogsTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks
    %w[run preview dispatch].each { |name| Rake::Task["audit_logs:#{name}"].reenable }
  end

  def invoke(name, *)
    out, = capture_io { Rake::Task["audit_logs:#{name}"].invoke(*) }
    out
  end

  test 'run stores the entries and reports them' do
    source = create_audit_log_source(script: 'json_lines.sh', name: 'Rake source')

    output = invoke('run', 'Rake source')

    assert_includes output, 'Rake source: success, 2 new entries'
    assert_equal 2, source.audit_log_entries.count
  end

  test 'run accepts an id' do
    source = create_audit_log_source(script: 'json_lines.sh')

    invoke('run', source.id.to_s)

    assert_equal 2, source.audit_log_entries.count
  end

  test 'preview shows what would be stored and stores nothing' do
    source = create_audit_log_source(script: 'json_lines.sh', name: 'Preview source')

    output = invoke('preview', 'Preview source')

    assert_includes output, '[DRY RUN]'
    assert_includes output, 'door opened'
    assert_includes output, 'new'
    assert_equal 0, source.audit_log_entries.count
    assert_equal 0, source.audit_log_runs.count
  end

  test 'run without a source aborts with usage' do
    assert_raises(SystemExit) { capture_io { Rake::Task['audit_logs:run'].invoke } }
  end

  test 'run with an unknown source fails' do
    assert_raises(ActiveRecord::RecordNotFound) { capture_io { Rake::Task['audit_logs:run'].invoke('nope') } }
  end

  test 'dispatch queues due sources' do
    source = create_audit_log_source(script: 'json_lines.sh')

    assert_enqueued_with(job: AuditLogs::RunSourceJob, args: [source.id]) do
      invoke('dispatch')
    end
  end

  include ActiveJob::TestHelper
end
