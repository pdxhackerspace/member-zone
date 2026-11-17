# Prometheus metrics for GET /metrics. See docs/metrics.md.
#
# The endpoint is off until METRICS_TOKEN is set, and so is the recording of job and request
# counters, so an installation that does not scrape pays nothing for it.
#
# Two kinds of metric come out of a scrape:
#
# - state read at scrape time, from the database, Sidekiq and Redis (the collectors);
# - counters and histograms accumulated between scrapes (Metrics::Recorder writes them to Redis
#   through Metrics::Store, because the web and Sidekiq processes that produce them are not the
#   process that answers the scrape).
module Metrics
  TOKEN_ENV = 'METRICS_TOKEN'.freeze
  CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8'.freeze

  COLLECTORS = {
    'build' => 'Metrics::BuildCollector',
    'members' => 'Metrics::MembersCollector',
    'activity' => 'Metrics::ActivityCollector',
    'integrations' => 'Metrics::IntegrationsCollector',
    'sidekiq' => 'Metrics::SidekiqCollector',
    'recorded' => 'Metrics::RecordedCollector',
    'infrastructure' => 'Metrics::InfrastructureCollector'
  }.freeze

  class << self
    def token
      ENV.fetch(TOKEN_ENV, '').strip.presence
    end

    def enabled?
      token.present?
    end

    def valid_token?(provided)
      expected = token
      expected.present? && provided.present? &&
        ActiveSupport::SecurityUtils.secure_compare(expected, provided.to_s)
    end

    # The whole exposition. A collector that raises costs its own metrics and nothing else: a
    # Redis outage must not hide the member counts, nor a slow query the queue depths. Which
    # collectors worked is itself a metric, so a partial scrape can be alerted on.
    def render
      registry = Registry.new
      outcomes = COLLECTORS.to_h { |name, class_name| [name, run_collector(class_name, registry)] }
      report_outcomes(registry, outcomes)
      registry.to_text
    end

    private

    def run_collector(class_name, registry)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      scratch = Registry.new
      class_name.constantize.new(scratch).collect
      registry.merge!(scratch)
      { success: 1, duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
    rescue StandardError => e
      Rails.logger.warn("[Metrics] #{class_name} failed: #{e.class}: #{e.message}")
      { success: 0, duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
    end

    def report_outcomes(registry, outcomes)
      success = registry.gauge('memberzone_scrape_collector_success',
                               'Whether a metrics collector completed during this scrape (1) or raised (0).')
      duration = registry.gauge('memberzone_scrape_collector_duration_seconds',
                                'How long a metrics collector took during this scrape.')
      outcomes.each do |name, outcome|
        success.set(outcome[:success], collector: name)
        duration.set(outcome[:duration].round(6), collector: name)
      end
    end
  end
end
