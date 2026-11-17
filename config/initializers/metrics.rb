# Feeds Metrics::Recorder, which keeps the job and request counters that GET /metrics exports.
# See docs/metrics.md. The recorder does nothing unless METRICS_TOKEN is set.
#
# Jobs are measured at the ActiveJob layer rather than with Sidekiq middleware: every job in the
# app is an ActiveJob, the event names the real job class instead of Sidekiq's wrapper, and it
# still reports an exception that retry_on swallows before Sidekiq could see it.
ActiveSupport::Notifications.subscribe('enqueue.active_job') do |event|
  Metrics::Recorder.job_enqueued(event.payload[:job]) unless event.payload[:exception_object]
end

ActiveSupport::Notifications.subscribe('perform.active_job') do |event|
  Metrics::Recorder.job_performed(event.payload[:job], event.duration / 1000.0, event.payload[:exception_object])
end

ActiveSupport::Notifications.subscribe('process_action.action_controller') do |event|
  Metrics::Recorder.request_processed(event.payload, event.duration / 1000.0)
end
