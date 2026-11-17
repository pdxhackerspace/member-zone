require 'test_helper'
require 'support/metrics_test_helper'
require 'sidekiq/api'

module Metrics
  class CollectorsTest < ActiveSupport::TestCase
    include MetricsTestHelper

    setup { Store.clear! }
    teardown { Store.clear! }

    def collect(collector)
      registry = Registry.new
      collector.new(registry).collect
      registry.to_text
    end

    test 'build info carries the version' do
      assert_equal 1.0, metric_value(collect(BuildCollector), 'memberzone_build_info',
                                     version: AppVersion.semver, commit: AppVersion.commit.to_s,
                                     ruby: RUBY_VERSION, rails: Rails.version, environment: 'test')
    end

    test 'members are counted by state, with a series for every state' do
      text = collect(MembersCollector)
      members = User.where(service_account: false)

      MembershipState::STATES.each do |state|
        assert_equal members.where(membership_state: state).count,
                     metric_value(text, 'memberzone_members', state: state), state
      end
      assert_equal members.where(active: true).count, metric_value(text, 'memberzone_members_active')
      assert_equal User.where(is_admin: true).count, metric_value(text, 'memberzone_admins')
    end

    test 'service accounts are not counted as members' do
      before = metric_value(collect(MembersCollector), 'memberzone_members', state: 'unknown')
      User.create!(full_name: 'Door Robot', service_account: true)
      text = collect(MembersCollector)

      assert_equal before, metric_value(text, 'memberzone_members', state: 'unknown')
      assert_equal User.where(service_account: true).count, metric_value(text, 'memberzone_service_accounts')
    end

    test 'activity counts match the database' do
      text = collect(ActivityCollector)

      MembershipApplication::STATUSES.each do |status|
        assert_equal MembershipApplication.where(status: status).count,
                     metric_value(text, 'memberzone_membership_applications', status: status), status
      end
      assert_equal Training.count, metric_value(text, 'memberzone_records', table: 'trainings')
      assert_equal ApiToken.usable.count, metric_value(text, 'memberzone_api_tokens', state: 'active')
    end

    test 'API tokens are counted by the state the model gives them' do
      member = users(:one)
      lapsed = 1.day.ago
      ApiToken.create!(user: member, created_by: member, name: 'Active')
      ApiToken.create!(user: member, created_by: member, name: 'Expired').update_columns(expires_at: lapsed)
      ApiToken.create!(user: member, created_by: member, name: 'Suspended').update_columns(suspended_at: lapsed)
      ApiToken.create!(user: member, created_by: member, name: 'Suspended and lapsed')
              .update_columns(suspended_at: lapsed, expires_at: lapsed)
      ApiToken.create!(user: member, created_by: member, name: 'Revoked')
              .update_columns(revoked_at: lapsed, suspended_at: lapsed, expires_at: lapsed)

      text = collect(ActivityCollector)

      expected = ApiToken.all.map(&:state).tally
      %w[active suspended expired revoked].each do |state|
        assert_equal expected.fetch(state, 0), metric_value(text, 'memberzone_api_tokens', state: state), state
      end
      assert_equal 2, expected['suspended']
    end

    test 'an integration reports whether it is up and its last status' do
      printer = Printer.create!(name: 'Front Desk Label Printer', cups_printer_name: 'front-desk')
      printer.update_columns(health_status: 'unhealthy', last_health_check_at: Time.zone.at(1_700_000_000))
      labels = { kind: 'printer', name: printer.name }

      text = collect(IntegrationsCollector)

      assert_equal 0.0, metric_value(text, 'memberzone_integration_up', labels)
      assert_equal 1.0, metric_value(text, 'memberzone_integration_status', labels.merge(status: 'unhealthy'))
      assert_equal 1_700_000_000.0, metric_value(text, 'memberzone_integration_last_check_timestamp_seconds', labels)

      printer.update_columns(health_status: 'healthy')

      assert_equal 1.0, metric_value(collect(IntegrationsCollector), 'memberzone_integration_up', labels)
    end

    test 'sidekiq queues are reported with their jobs by class' do
      queue = "metrics-test-#{Process.pid}-#{SecureRandom.hex(4)}"
      ::Sidekiq::Client.push('class' => 'Metrics::CollectorsTest::NeverRun', 'queue' => queue, 'args' => [])
      text = collect(SidekiqCollector)

      assert_equal 1.0, metric_value(text, 'sidekiq_queue_size', queue: queue)
      assert_equal 1.0, metric_value(text, 'sidekiq_queue_jobs_by_class',
                                     queue: queue, job: 'Metrics::CollectorsTest::NeverRun')
      assert_includes text, '# TYPE sidekiq_processed_jobs_total counter'
    ensure
      ::Sidekiq::Queue.new(queue).clear
    end

    test 'recurring jobs are described' do
      name = "Metrics Test #{Process.pid} #{SecureRandom.hex(4)}"
      ::Sidekiq::Cron::Job.create(name: name, cron: '0 3 * * *', class: 'Membership::TickJob', active_job: true)
      text = collect(SidekiqCollector)

      assert_equal 1.0, metric_value(text, 'sidekiq_cron_job_info',
                                     name: name, job: 'Membership::TickJob', cron: '0 3 * * *')
      assert_equal 1.0, metric_value(text, 'sidekiq_cron_job_enabled', name: name)
    ensure
      ::Sidekiq::Cron::Job.destroy(name)
    end

    test 'recorded counters are exported as counters and histograms' do
      Store.write do |writer|
        writer.increment('job_executions', %w[SomeJob default success], 3)
        writer.increment('job_failures', %w[SomeJob Timeout::Error])
        writer.observe('job_duration', %w[SomeJob default], 0.4, Recorder::JOB_BUCKETS)
        writer.observe('job_duration', %w[SomeJob default], 7, Recorder::JOB_BUCKETS)
      end
      text = collect(RecordedCollector)
      labels = { job: 'SomeJob', queue: 'default' }

      assert_equal 3.0, metric_value(text, 'memberzone_job_executions_total', labels.merge(status: 'success'))
      assert_equal 1.0, metric_value(text, 'memberzone_job_failures_total', job: 'SomeJob', error: 'Timeout::Error')
      assert_equal 0.0, metric_value(text, 'memberzone_job_duration_seconds_bucket', labels.merge(le: '0.1'))
      assert_equal 1.0, metric_value(text, 'memberzone_job_duration_seconds_bucket', labels.merge(le: '0.5'))
      assert_equal 2.0, metric_value(text, 'memberzone_job_duration_seconds_bucket', labels.merge(le: '+Inf'))
      assert_in_delta 7.4, metric_value(text, 'memberzone_job_duration_seconds_sum', labels)
      assert_equal 2.0, metric_value(text, 'memberzone_job_duration_seconds_count', labels)
    end

    test 'the database and redis are described' do
      text = collect(InfrastructureCollector)

      assert_operator metric_value(text, 'memberzone_database_size_bytes'), :>, 0
      assert_equal 0.0, metric_value(text, 'memberzone_database_pending_migrations')
      assert_operator metric_value(text, 'memberzone_redis_memory_used_bytes'), :>, 0
    end

    test 'a collector that raises costs only its own metrics' do
      failing = ->(*) { raise 'sidekiq is down' }

      text = with_replaced_method(SidekiqCollector, :new, failing) { Metrics.render }

      assert_equal 0.0, metric_value(text, 'memberzone_scrape_collector_success', collector: 'sidekiq')
      assert_equal 1.0, metric_value(text, 'memberzone_scrape_collector_success', collector: 'members')
      assert_not_includes text, 'sidekiq_enqueued_jobs'
      assert_includes text, 'memberzone_members{'
    end
  end
end
