module Metrics
  # Turns job and request events into counters in Metrics::Store. Subscribed to
  # ActiveSupport::Notifications in config/initializers/metrics.rb.
  #
  # Recording is best effort: it runs inside every job and at the end of every request, so a
  # Redis hiccup here must never fail the work being measured.
  module Recorder
    JOB_BUCKETS = [0.1, 0.5, 1, 5, 15, 60, 300, 1800].freeze
    REQUEST_BUCKETS = [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10].freeze

    module_function

    def job_enqueued(job)
      return unless Metrics.enabled?

      guarded { Store.write { |w| w.increment('jobs_enqueued', [job.class.name, job.queue_name]) } }
    end

    # An exception counts as a failure even when ActiveJob's retry_on goes on to handle it:
    # the attempt failed, and that is what a failure rate should show.
    def job_performed(job, seconds, error = nil)
      return unless Metrics.enabled?

      name = job.class.name
      status = error ? 'failure' : 'success'
      guarded do
        Store.write do |w|
          w.increment('job_executions', [name, job.queue_name, status])
          w.observe('job_duration', [name, job.queue_name], seconds, JOB_BUCKETS)
          w.set("job_last_#{status}", [name], Time.current.to_f)
          w.increment('job_failures', [name, error.class.name]) if error
        end
      end
    end

    def request_processed(payload, seconds)
      return unless Metrics.enabled?

      controller = payload[:controller].to_s
      action = payload[:action].to_s
      labels = [controller, action, payload[:method].to_s, request_status(payload).to_s]
      guarded do
        Store.write do |w|
          w.increment('http_requests', labels)
          w.observe('http_request_duration', [controller, action], seconds, REQUEST_BUCKETS)
        end
      end
    end

    # An action that raised has no status yet; Rails decides it later from the exception.
    def request_status(payload)
      return payload[:status] if payload[:status]

      exception_class = payload[:exception]&.first
      exception_class ? ActionDispatch::ExceptionWrapper.status_code_for_exception(exception_class) : 0
    end

    def guarded
      yield
    rescue StandardError => e
      Rails.logger.debug { "[Metrics] could not record: #{e.class}: #{e.message}" }
    end
  end
end
