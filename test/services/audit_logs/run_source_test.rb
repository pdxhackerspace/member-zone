require 'test_helper'

module AuditLogs
  class RunSourceTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    test 'runs the program, stores its entries and records a successful run' do
      source = create_audit_log_source(script: 'json_lines.sh', environment_variables: 'AUDIT_TEST_TOKEN=abc')

      run = RunSource.call(source)

      assert_equal 'success', run.status
      assert_equal 0, run.exit_code
      assert_equal 2, run.entries_added
      assert_equal ['door opened', 'token=abc'], source.audit_log_entries.order(:occurred_at).pluck(:message)
      assert_includes run.command_line, 'json_lines.sh'

      source.reload
      assert_equal 'success', source.run_status
      assert_in_delta Time.current, source.last_run_at, 10.seconds
      assert_equal Time.utc(2026, 9, 29, 10, 5), source.last_entry_at
    end

    test 'running again stores nothing twice' do
      source = create_audit_log_source(script: 'json_lines.sh')
      RunSource.call(source)

      run = RunSource.call(source.reload)

      assert_equal 0, run.entries_added
      assert_equal 2, source.audit_log_entries.count
      assert_equal 2, source.audit_log_runs.count
    end

    test 'plain text output is stored and not repeated on the next run' do
      source = create_audit_log_source(script: 'plain.sh')

      assert_equal 3, RunSource.call(source).entries_added
      assert_equal 0, RunSource.call(source.reload).entries_added
    end

    test 'a failing program still keeps the lines it printed and records the failure' do
      source = create_audit_log_source(script: 'failing.sh')

      run = RunSource.call(source)

      assert_equal 'failed', run.status
      assert_equal 3, run.exit_code
      assert_equal 1, run.entries_added
      assert_includes run.output, 'something broke'
      assert_equal 'failed', source.reload.run_status
      assert_equal ['got this far'], source.audit_log_entries.pluck(:message)
    end

    test 'a program that cannot be started is recorded as failed instead of raising' do
      source = create_audit_log_source(script_path: '/nonexistent/audit-log/nope.sh')

      run = RunSource.call(source)

      assert_equal 'failed', run.status
      assert_includes run.output, 'Errno::ENOENT'
      assert_equal 'failed', source.reload.run_status
      assert_predicate source.audit_log_entries, :none?
    end

    test 'stderr output is kept on the run and not stored as log entries' do
      source = create_audit_log_source(script: 'failing.sh')
      RunSource.call(source)

      assert_not(source.audit_log_entries.any? { |e| e.message.include?('something broke') })
    end

    test 'the next run is told when the newest stored entry occurred' do
      source = create_audit_log_source(script: 'json_lines.sh')
      RunSource.call(source)

      assert_equal Time.utc(2026, 9, 29, 10, 5), source.reload.last_entry_at
      environment = ScriptRunner.new(source, source.last_entry_at, 1).environment
      assert_equal '2026-09-29T10:05:00Z', environment['AUDIT_LOG_SINCE']
    end

    test 'a future timestamp cannot push the cursor ahead of the run' do
      source = create_audit_log_source(script: 'future.sh')

      before = Time.current
      RunSource.call(source)

      source.reload
      assert_equal 2, source.audit_log_entries.count
      assert_operator source.last_entry_at, :<=, Time.current
      assert_operator source.last_entry_at, :>=, before - 1.minute
    end

    test 'the cursor still advances to real entry times and never moves backwards' do
      source = create_audit_log_source(script: 'json_lines.sh')
      RunSource.call(source)
      assert_equal Time.utc(2026, 9, 29, 10, 5), source.reload.last_entry_at

      source.update!(last_entry_at: Time.utc(2026, 9, 30))
      RunSource.call(source)
      assert_equal Time.utc(2026, 9, 30), source.reload.last_entry_at
    end

    test 'a run that stores nothing leaves the cursor where it was' do
      source = create_audit_log_source(script: 'json_lines.sh')
      RunSource.call(source)
      cursor = source.reload.last_entry_at

      RunSource.call(source)

      assert_equal 0, source.audit_log_runs.order(:id).last.entries_added
      assert_equal cursor, source.reload.last_entry_at
    end

    test 'a first run that prints nothing does not set a cursor' do
      source = create_audit_log_source(script: 'empty.sh')

      RunSource.call(source)

      assert_nil source.reload.last_entry_at
      assert_equal 'success', source.run_status
    end

    test 'a failed run that stored nothing does not set a cursor' do
      source = create_audit_log_source(script_path: '/nonexistent/nope.sh')

      RunSource.call(source)

      assert_nil source.reload.last_entry_at
    end

    test 'the program is handed a cursor that is not in the future after a run with skewed timestamps' do
      source = create_audit_log_source(script: 'future.sh')
      RunSource.call(source)

      since = ScriptRunner.new(source.reload, source.last_entry_at, 1).environment['AUDIT_LOG_SINCE']
      assert_operator Time.iso8601(since), :<=, Time.current
    end

    test 'alerts fire for new matching entries only' do
      source = create_audit_log_source(script: 'json_lines.sh')
      source.audit_log_alert_rules.create!(name: 'door', pattern: 'door opened')
      admin = users(:one)
      admin.update_columns(is_admin: true)
      ActionMailer::Base.deliveries.clear

      perform_enqueued_jobs { RunSource.call(source) }
      assert_equal 1, ActionMailer::Base.deliveries.size

      perform_enqueued_jobs { RunSource.call(source.reload) }
      assert_equal 1, ActionMailer::Base.deliveries.size, 're-printed entries must not alert again'
    end
  end
end
