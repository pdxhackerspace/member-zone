require 'test_helper'

module AuditLogs
  class DispatchJobTest < ActiveJob::TestCase
    test 'queues a run for each due, enabled source' do
      due = create_audit_log_source(run_interval: 'hourly', last_run_at: 2.hours.ago)
      never_run = create_audit_log_source
      create_audit_log_source(run_interval: 'daily', last_run_at: 1.hour.ago)
      create_audit_log_source(enabled: false)
      running = create_audit_log_source(run_interval: 'hourly')
      running.update!(run_status: 'running', last_run_at: 5.minutes.ago)

      DispatchJob.perform_now

      assert_enqueued_jobs 2, only: RunSourceJob
      assert_enqueued_with(job: RunSourceJob, args: [due.id])
      assert_enqueued_with(job: RunSourceJob, args: [never_run.id])
    end

    test 'each interval comes round when it has elapsed' do
      spans = { 'hourly' => 1.hour, 'every_6_hours' => 6.hours, 'every_12_hours' => 12.hours, 'daily' => 1.day }
      spans.each do |interval, span|
        source = create_audit_log_source(run_interval: interval, last_run_at: span.ago)
        assert source.due?, "#{interval} should be due after #{span.inspect}"

        source.update!(last_run_at: span.ago + 30.minutes)
        assert_not source.due?, "#{interval} should not be due only #{(span - 30.minutes).inspect} after its last run"
      end
    end

    test 'is registered to run hourly' do
      cron = Rails.root.join('config/initializers/sidekiq.rb').read

      assert_match(/AuditLogs::DispatchJob/, cron)
    end
  end
end
