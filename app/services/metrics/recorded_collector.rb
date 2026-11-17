module Metrics
  # The counters Metrics::Recorder accumulates between scrapes: what each job class and each
  # controller action has done since recording began, with how long it took.
  class RecordedCollector < Collector
    def collect
      jobs
      job_timestamps
      requests
    end

    private

    def jobs
      counter('memberzone_jobs_enqueued_total', 'Jobs enqueued, by job class and queue.')
        .set_grouped(Store.read('jobs_enqueued'), :job, :queue)
      counter('memberzone_job_executions_total', 'Job executions, by job class, queue and outcome.')
        .set_grouped(Store.read('job_executions'), :job, :queue, :status)
      counter('memberzone_job_failures_total', 'Failed job executions, by job class and exception class.')
        .set_grouped(Store.read('job_failures'), :job, :error)
      distribution('job_duration', Recorder::JOB_BUCKETS, %i[job queue],
                   histogram('memberzone_job_duration_seconds', 'How long job executions took.'))
    end

    def job_timestamps
      gauge('memberzone_job_last_success_timestamp_seconds', 'When a job class last finished successfully.')
        .set_grouped(Store.read('job_last_success'), :job)
      gauge('memberzone_job_last_failure_timestamp_seconds', 'When a job class last failed.')
        .set_grouped(Store.read('job_last_failure'), :job)
    end

    def requests
      counter('memberzone_http_requests_total', 'Requests handled, by controller, action, method and status.')
        .set_grouped(Store.read('http_requests'), :controller, :action, :method, :status)
      distribution('http_request_duration', Recorder::REQUEST_BUCKETS, %i[controller action],
                   histogram('memberzone_http_request_duration_seconds', 'How long requests took to handle.'))
    end

    # Regroups the stored per-bucket counts into one histogram series per label set.
    def distribution(family, buckets, label_names, target)
      counts = Hash.new { |hash, key| hash[key] = {} }
      Store.read("#{family}:bucket").each { |(*values, bound), count| counts[values][bound] = count }
      sums = Store.read("#{family}:sum")
      counts.each do |values, bucket_counts|
        target.set_distribution(label_names.zip(values).to_h, buckets, bucket_counts, sums.fetch(values, 0))
      end
    end
  end
end
