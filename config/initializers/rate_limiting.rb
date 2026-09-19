# SPDX-FileCopyrightText: 2025 John Romkey
#
# SPDX-License-Identifier: CC0-1.0

# Somewhere to keep rate limit counters.
#
# ActionController::RateLimiting reaches for Rails.cache when no store is given, and that
# default is wrong here twice over. The test environment sets :null_store, so every limit
# would silently count to zero and no test could tell an enforced limit from an absent one.
# Production leaves config.cache_store unset, which lands on a per-container file store that
# two web containers would not share — so the limit would be per container rather than per
# deployment. Redis is already a hard dependency for Sidekiq and the RFID handoff, so the
# counters go there and every process sees the same ones.
#
# This lives in an initializer rather than under lib/ deliberately: it is read while
# controller classes are being defined (rate_limit resolves its store then), and a constant
# defined here is not swept away by a reload in development.
module RateLimiting
  # Counters are namespaced so that flushing them can never take out a Sidekiq queue or a
  # pending RFID scan sharing the same Redis database.
  NAMESPACE = 'rate_limit'.freeze

  class << self
    def store
      @store ||= build_store
    end

    # Rate limit counters outlive a single test, and an IP-keyed counter is shared by every
    # test in a process. Tests that assert on a limit have to start from zero.
    def reset!
      store.clear
    end

    private

    def build_store
      # Parallel test workers share one Redis, and an IP-keyed counter is the same key in
      # every worker, so worker 2 would inherit worker 1's count. A per-process store keeps
      # them from seeing each other.
      return ActiveSupport::Cache::MemoryStore.new if Rails.env.test?

      redis_url = ENV.fetch('REDIS_URL', nil)
      if redis_url.blank?
        Rails.logger.warn(
          '[RateLimiting] REDIS_URL is unset, so rate limit counters are per-process and a ' \
          'limit of N allows N requests per running process.'
        )
        return ActiveSupport::Cache::MemoryStore.new
      end

      ActiveSupport::Cache::RedisCacheStore.new(
        url: redis_url,
        namespace: NAMESPACE,
        # Redis being unreachable must not lock everyone out of signing in. The store returns
        # nil on failure, which ActionController reads as "under the limit", so an outage
        # degrades to unlimited attempts rather than to a closed door. That is the right trade
        # for a login page, but it is a real gap while it lasts, hence the error-level log.
        error_handler: lambda { |method:, returning:, exception:|
          Rails.logger.error(
            "[RateLimiting] Redis #{method} failed, rate limiting is not being enforced: " \
            "#{exception.class}: #{exception.message} (returning #{returning.inspect})"
          )
        }
      )
    end
  end
end
