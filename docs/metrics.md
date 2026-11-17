# Prometheus metrics

Member Zone exposes its state at `GET /metrics` in the Prometheus text exposition format: the roster, the work
passing through the app, the health of everything it talks to, the Sidekiq queues, servers and schedule, and
counters and timings for every job class and controller action.

## Turning it on

The endpoint is off until `METRICS_TOKEN` is set. Generate a token and set it on **both** the web and the Sidekiq
containers:

```bash
openssl rand -hex 32
```

```bash
METRICS_TOKEN=<the value>
```

The variable does two things, which is why both processes need it:

- the web process answers `/metrics` only when it is set (otherwise the route returns 404);
- the web and Sidekiq processes only keep request and job counters while it is set, so an installation that does
  not scrape pays nothing.

To rotate the token, change the variable and restart; there is nothing stored.

## Authentication

Send the token as a bearer token:

```bash
curl -H "Authorization: Bearer $METRICS_TOKEN" https://members.example.com/metrics
```

| Response | Meaning |
| --- | --- |
| 200 | The exposition, `text/plain; version=0.0.4`. |
| 401 | Token missing or wrong. A signed-in session does not help; only the token is accepted. |
| 404 | `METRICS_TOKEN` is not set, so the endpoint is off. |
| 429 | More than 60 requests in a minute from one address (counted before authentication). |

The token is read from the `Authorization` header only — never from a query parameter, which would leak into
access logs. It is a single shared secret rather than a member API token on purpose: a scraper is not a member,
holds no privileges, and should not stop working when a token expires. It grants nothing but this endpoint.

Metrics include counts of members, payment totals per processor, and the names of printers, access controllers
and other integrations. They contain no member names, emails or other personal data, but treat the token as a
secret and scrape over HTTPS.

## Prometheus configuration

```yaml
scrape_configs:
  - job_name: memberzone
    scheme: https
    metrics_path: /metrics
    scrape_interval: 60s
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/memberzone.token
    static_configs:
      - targets: ['members.example.com']
```

A scrape runs a few dozen `COUNT` queries and reads the Sidekiq sets; 30–60 seconds is a sensible interval. Scrape
the site once, not each web container: every metric is read from the shared database and Redis, so each container
gives the same answer.

## What is exported

Every family carries `# HELP` text, so the endpoint itself is the complete reference. In outline:

### Build and scrape

| Metric | Labels | |
| --- | --- | --- |
| `memberzone_build_info` | `version`, `commit`, `ruby`, `rails`, `environment` | Always 1. |
| `memberzone_scrape_collector_success` | `collector` | 1 if that group of metrics was gathered, 0 if it raised. |
| `memberzone_scrape_collector_duration_seconds` | `collector` | How long that group took. |

The collectors are `build`, `members`, `activity`, `integrations`, `sidekiq`, `recorded` and `infrastructure`.
One failing does not fail the scrape — its metrics are simply absent and its `success` is 0 — so alert on
`memberzone_scrape_collector_success == 0`.

### Members

| Metric | Labels | |
| --- | --- | --- |
| `memberzone_members` | `state` | Members by membership state; every state has a series. Service accounts are excluded. |
| `memberzone_members_active` | | Members whose standing counts as active. |
| `memberzone_members_by_payment_type` | `payment_type` | |
| `memberzone_members_by_dues_status` | `dues_status` | |
| `memberzone_members_signed_in` | `window` (`24h`, `7d`, `30d`) | Members who last signed in within the window. |
| `memberzone_members_created_30d` | | |
| `memberzone_admins`, `memberzone_service_accounts` | | |

### Activity

| Metric | Labels |
| --- | --- |
| `memberzone_membership_applications` | `status` |
| `memberzone_queued_mails` | `status` |
| `memberzone_queued_mails_unsent`, `memberzone_queued_mails_failing`, `memberzone_queued_mail_oldest_unsent_timestamp_seconds` | |
| `memberzone_parking_notices` | `notice_type`, `status` |
| `memberzone_incident_reports` | `status` |
| `memberzone_credentials` | `status` |
| `memberzone_api_tokens` | `state` (`active`, `suspended`, `expired`, `revoked`) |
| `memberzone_api_tokens_used_24h` | |
| `memberzone_payment_events` | `source`, `event_type` |
| `memberzone_payment_event_last_timestamp_seconds` | |
| `memberzone_access_logs_24h`, `memberzone_access_log_last_timestamp_seconds` | |
| `memberzone_records` | `table` — row counts for the larger tables |

### Integrations

Access controllers, printers, AI profiles, credential providers, audit log sources, member sources and payment
processors all record the outcome of their own health check or sync. They are exported in one shape, labelled
`kind` and `name`:

| Metric | |
| --- | --- |
| `memberzone_integration_up` | 1 if the last check or sync succeeded. |
| `memberzone_integration_enabled` | 1 if switched on. Alert on `up == 0 and enabled == 1`. |
| `memberzone_integration_status` | Always 1, with the recorded outcome in a `status` label. |
| `memberzone_integration_last_check_timestamp_seconds` | |
| `memberzone_integration_last_success_timestamp_seconds` | Where the integration records it. |
| `memberzone_integration_consecutive_errors` | Member sources and payment processors. |

Plus `memberzone_access_controller_{sync,backup}_status`, `memberzone_access_controller_last_{sync,backup}_timestamp_seconds`,
`memberzone_payment_processor_payments{processor,match}`, `memberzone_payment_processor_amount_30d` and
`memberzone_payment_processor_webhook_last_timestamp_seconds`.

### Sidekiq

Read from Sidekiq at scrape time.

| Metric | Labels | |
| --- | --- | --- |
| `sidekiq_processed_jobs_total`, `sidekiq_failed_jobs_total` | | Sidekiq's own lifetime counters. |
| `sidekiq_enqueued_jobs`, `sidekiq_scheduled_jobs`, `sidekiq_retry_jobs`, `sidekiq_dead_jobs` | | |
| `sidekiq_busy_threads`, `sidekiq_processes` | | |
| `sidekiq_queue_size`, `sidekiq_queue_latency_seconds` | `queue` | Latency is the age of the oldest waiting job. |
| `sidekiq_queue_jobs_by_class` | `queue`, `job` | |
| `sidekiq_scheduled_jobs_by_class` | `job` | |
| `sidekiq_retry_jobs_by_class`, `sidekiq_dead_jobs_by_class` | `job`, `error` | What is failing, and with which exception. |
| `sidekiq_running_jobs` | `job`, `queue` | |
| `sidekiq_longest_running_job_seconds` | | 0 when nothing is running. |
| `sidekiq_process_info` | `hostname`, `pid`, `tag`, `version`, `queues` | One series per Sidekiq server. |
| `sidekiq_process_{concurrency,busy_threads,rss_bytes,start_timestamp_seconds,heartbeat_timestamp_seconds,quiet}` | `hostname`, `pid` | |
| `sidekiq_cron_job_info` | `name`, `job`, `cron` | One series per recurring job. |
| `sidekiq_cron_job_enabled`, `sidekiq_cron_job_last_enqueue_timestamp_seconds` | `name` | |

The `_by_class` breakdowns read at most the first 1000 entries of a set; the totals are always exact.

### Jobs and requests

Counted as they happen (see below) rather than read at scrape time.

| Metric | Labels | |
| --- | --- | --- |
| `memberzone_jobs_enqueued_total` | `job`, `queue` | |
| `memberzone_job_executions_total` | `job`, `queue`, `status` (`success`, `failure`) | |
| `memberzone_job_failures_total` | `job`, `error` | By exception class. |
| `memberzone_job_duration_seconds` | `job`, `queue` | Histogram: 0.1 s to 30 min. |
| `memberzone_job_last_success_timestamp_seconds`, `memberzone_job_last_failure_timestamp_seconds` | `job` | |
| `memberzone_http_requests_total` | `controller`, `action`, `method`, `status` | |
| `memberzone_http_request_duration_seconds` | `controller`, `action` | Histogram: 50 ms to 10 s. |

A job execution that raises is a failure even if the job's own `retry_on` then handles it, so the failure rate
reflects attempts, not just what reaches Sidekiq's retry set.

### Infrastructure

`memberzone_database_size_bytes`, `memberzone_database_connections{state}`, `memberzone_database_pending_migrations`,
`memberzone_redis_memory_used_bytes`, `memberzone_redis_memory_peak_bytes`, `memberzone_redis_connected_clients`,
`memberzone_redis_uptime_seconds`, `memberzone_redis_info{version}`.

## Example queries and alerts

```promql
# Job failure ratio by class over 15 minutes
sum by (job) (rate(memberzone_job_executions_total{status="failure"}[15m]))
  / sum by (job) (rate(memberzone_job_executions_total[15m]))

# 95th percentile job duration by class
histogram_quantile(0.95, sum by (job, le) (rate(memberzone_job_duration_seconds_bucket[30m])))

# A daily job that has not succeeded in over a day
time() - memberzone_job_last_success_timestamp_seconds{job="Membership::TickJob"} > 90000

# No Sidekiq server, or a queue backing up
sidekiq_processes == 0
sidekiq_queue_latency_seconds > 300

# An enabled integration that is down
memberzone_integration_up == 0 and on (kind, name) memberzone_integration_enabled == 1

# Mail stuck in the queue for more than an hour
time() - memberzone_queued_mail_oldest_unsent_timestamp_seconds > 3600

# Server errors
sum(rate(memberzone_http_requests_total{status=~"5.."}[5m]))
```

## How it works

`MetricsController` authenticates and renders `Metrics.render`, which runs each collector in
`app/services/metrics/` against a `Metrics::Registry` and prints it.

Most metrics are read at scrape time. The job and request counters cannot be: they are produced in every Puma
worker and Sidekiq process, while a scrape is answered by one web process. `config/initializers/metrics.rb`
subscribes `Metrics::Recorder` to the `perform.active_job`, `enqueue.active_job` and
`process_action.action_controller` notifications, and the recorder writes to Redis hashes (`mz_metrics:*`, in
Sidekiq's Redis) through `Metrics::Store` — one pipelined round trip per event. Recording is best effort: a Redis
error is swallowed, never raised into the job or request.

The counters live in Redis, so they survive deploys and restarts and only reset if Redis is flushed (Prometheus
handles a counter reset). To clear them deliberately: `Metrics::Store.clear!` from a console.

To add a metric, add it to the collector it belongs with (or write a new `Metrics::Collector` subclass and list
it in `Metrics::COLLECTORS`), give it help text, and keep label values bounded — never a member, an id, or free
text.
