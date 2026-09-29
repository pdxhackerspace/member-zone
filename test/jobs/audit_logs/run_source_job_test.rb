require 'test_helper'

module AuditLogs
  class RunSourceJobTest < ActiveJob::TestCase
    test 'runs the source' do
      source = create_audit_log_source(script: 'json_lines.sh')

      RunSourceJob.perform_now(source.id)

      assert_equal 2, source.audit_log_entries.count
      assert_equal 'success', source.reload.run_status
    end

    test 'does nothing for a missing or disabled source' do
      RunSourceJob.perform_now(0)

      source = create_audit_log_source(script: 'json_lines.sh', enabled: false)
      RunSourceJob.perform_now(source.id)

      assert_equal 0, source.audit_log_entries.count
      assert_equal 0, source.audit_log_runs.count
    end

    test 'does not run a source another worker is already running' do
      source = create_audit_log_source(script: 'json_lines.sh')
      source.update!(run_status: 'running', last_run_at: 1.minute.ago)

      RunSourceJob.perform_now(source.id)

      assert_equal 0, source.audit_log_runs.count
    end

    test 'takes over a run that went stale' do
      source = create_audit_log_source(script: 'json_lines.sh')
      source.update!(run_status: 'running', last_run_at: 3.hours.ago)

      RunSourceJob.perform_now(source.id)

      assert_equal 1, source.audit_log_runs.count
    end

    test 'uses the default queue' do
      assert_equal 'default', RunSourceJob.new.queue_name
      assert_equal 'default', DispatchJob.new.queue_name
    end
  end
end
