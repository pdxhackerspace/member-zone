module Metrics
  # The database and Redis underneath the app.
  class InfrastructureCollector < Collector
    REDIS_GAUGES = {
      'used_memory' => ['memberzone_redis_memory_used_bytes', 'Memory Redis has allocated.'],
      'used_memory_peak' => ['memberzone_redis_memory_peak_bytes', 'Peak memory Redis has allocated.'],
      'connected_clients' => ['memberzone_redis_connected_clients', 'Client connections open to Redis.'],
      'uptime_in_seconds' => ['memberzone_redis_uptime_seconds', 'How long Redis has been up.']
    }.freeze

    def collect
      database
      redis
    end

    private

    def database
      connection = ActiveRecord::Base.connection
      gauge('memberzone_database_size_bytes', 'Size of the application database on disk.',
            connection.select_value('SELECT pg_database_size(current_database())').to_i)
      states = connection.select_rows(<<~SQL.squish)
        SELECT COALESCE(state, 'none'), COUNT(*) FROM pg_stat_activity
        WHERE datname = current_database() GROUP BY 1
      SQL
      gauge('memberzone_database_connections', 'Connections to the application database, by state.')
        .set_grouped(states.to_h, :state)
      gauge('memberzone_database_pending_migrations', 'Migrations not yet applied to the database.',
            connection.pool.migration_context.open.pending_migrations.size)
    end

    def redis
      info = ::Sidekiq.redis(&:info)
      REDIS_GAUGES.each { |key, (name, help)| gauge(name, help, info[key]&.to_i) }
      gauge('memberzone_redis_info', 'Always 1; the labels describe the Redis server.', 1,
            version: info['redis_version'].to_s)
    end
  end
end
