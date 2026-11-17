require 'sidekiq/api'
require 'sidekiq/cron'

module Metrics
  # Background job machinery as Sidekiq sees it now: totals, queues, the server processes,
  # what is waiting, running, retrying or dead (by job class), and the cron schedule.
  class SidekiqCollector < Collector
    # Breaking a set down by class means reading its entries; past this many the breakdown
    # covers the first entries only (the totals stay exact).
    SAMPLE_LIMIT = 1000

    def collect
      totals
      queues
      processes
      running
      backlog_by_class
      cron
    end

    private

    def totals
      stats = ::Sidekiq::Stats.new
      counter('sidekiq_processed_jobs_total', 'Jobs Sidekiq has processed.', stats.processed)
      counter('sidekiq_failed_jobs_total', 'Job executions Sidekiq has seen fail.', stats.failed)
      gauge('sidekiq_enqueued_jobs', 'Jobs waiting in all queues.', stats.enqueued)
      gauge('sidekiq_scheduled_jobs', 'Jobs scheduled to run later.', stats.scheduled_size)
      gauge('sidekiq_retry_jobs', 'Failed jobs waiting to be retried.', stats.retry_size)
      gauge('sidekiq_dead_jobs', 'Jobs that ran out of retries.', stats.dead_size)
      gauge('sidekiq_busy_threads', 'Threads currently running a job.', stats.workers_size)
      gauge('sidekiq_processes', 'Sidekiq server processes with a current heartbeat.', stats.processes_size)
    end

    def queues
      size = gauge('sidekiq_queue_size', 'Jobs waiting in a queue.')
      latency = gauge('sidekiq_queue_latency_seconds', 'Age of the oldest job waiting in a queue.')
      by_class = gauge('sidekiq_queue_jobs_by_class', 'Jobs waiting in a queue, by job class.')
      all_queues = ::Sidekiq::Queue.all
      all_queues.each do |queue|
        size.set(queue.size, queue: queue.name)
        latency.set(queue.latency.round(3), queue: queue.name)
        tally(queue).each { |job, count| by_class.set(count, queue: queue.name, job: job) }
      end
    end

    def processes
      info = gauge('sidekiq_process_info', 'Always 1; the labels describe a Sidekiq server process.')
      families = process_families
      ::Sidekiq::ProcessSet.new.each do |process|
        labels = { hostname: process['hostname'].to_s, pid: process['pid'].to_s }
        info.set(1, labels.merge(tag: process['tag'].to_s, version: process['version'].to_s,
                                 queues: Array(process['queues']).join(',')))
        families.each { |key, family| family.set(process_value(process, key), labels) }
      end
    end

    def process_families
      {
        concurrency: gauge('sidekiq_process_concurrency', 'Threads a Sidekiq process runs jobs on.'),
        busy: gauge('sidekiq_process_busy_threads', 'Threads of a Sidekiq process currently running a job.'),
        rss: gauge('sidekiq_process_rss_bytes', 'Resident memory of a Sidekiq process.'),
        started: gauge('sidekiq_process_start_timestamp_seconds', 'When a Sidekiq process started.'),
        beat: gauge('sidekiq_process_heartbeat_timestamp_seconds', 'When a Sidekiq process last reported in.'),
        quiet: gauge('sidekiq_process_quiet', 'Whether a Sidekiq process has stopped taking new jobs.')
      }
    end

    def process_value(process, key)
      case key
      when :concurrency then process['concurrency'].to_i
      when :busy then process['busy'].to_i
      when :rss then process['rss'].to_i * 1024
      when :started then process['started_at'].to_f
      when :beat then process['beat'].to_f
      when :quiet then process['quiet'].to_s == 'true'
      end
    end

    def running
      works = ::Sidekiq::WorkSet.new.map { |_process, _thread, work| work }
      gauge('sidekiq_running_jobs', 'Jobs running right now, by job class.')
        .set_grouped(works.map { |work| [work.job.display_class, work.queue] }.tally, :job, :queue)
      oldest = works.map(&:run_at).min
      gauge('sidekiq_longest_running_job_seconds', 'How long the longest-running current job has been going.',
            oldest ? (Time.current - oldest).round(3) : 0)
    end

    def backlog_by_class
      gauge('sidekiq_scheduled_jobs_by_class', 'Jobs scheduled to run later, by job class.')
        .set_grouped(tally(::Sidekiq::ScheduledSet.new), :job)
      gauge('sidekiq_retry_jobs_by_class', 'Failed jobs waiting to be retried, by job class and error.')
        .set_grouped(tally_errors(::Sidekiq::RetrySet.new), :job, :error)
      gauge('sidekiq_dead_jobs_by_class', 'Jobs that ran out of retries, by job class and error.')
        .set_grouped(tally_errors(::Sidekiq::DeadSet.new), :job, :error)
    end

    def tally(entries)
      entries.first(SAMPLE_LIMIT).map(&:display_class).tally
    end

    def tally_errors(entries)
      entries.first(SAMPLE_LIMIT).map { |entry| [entry.display_class, entry['error_class'].to_s] }.tally
    end

    def cron
      info = gauge('sidekiq_cron_job_info', 'Always 1; the labels describe a recurring job.')
      enabled = gauge('sidekiq_cron_job_enabled', 'Whether a recurring job is enabled.')
      last = gauge('sidekiq_cron_job_last_enqueue_timestamp_seconds', 'When a recurring job was last enqueued.')
      cron_jobs = ::Sidekiq::Cron::Job.all
      cron_jobs.each do |job|
        info.set(1, name: job.name, job: job.klass.to_s, cron: job.cron.to_s)
        enabled.set(job.status == 'enabled', name: job.name)
        last.set(job.last_enqueue_time, name: job.name)
      end
    end
  end
end
