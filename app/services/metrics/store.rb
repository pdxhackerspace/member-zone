module Metrics
  # Counters that accumulate between scrapes, kept in Redis.
  #
  # They cannot live in process memory: requests are counted in every Puma worker and jobs in
  # every Sidekiq process, while a scrape is answered by whichever web process it lands on. Redis
  # is the one place they all reach, and it is already a hard dependency (Sidekiq's Redis is used).
  #
  # Each family is one Redis hash; the field is the JSON array of label values and the value is
  # the number. A histogram is two hashes, `<family>:bucket` (label values plus the upper bound
  # the observation fell under — not cumulative) and `<family>:sum`.
  module Store
    ROOT = 'mz_metrics'.freeze

    # Queues writes onto one Redis pipeline so recording an event is a single round trip.
    class Writer
      def initialize(pipeline)
        @pipeline = pipeline
      end

      def increment(family, labels, by = 1)
        @pipeline.call('HINCRBY', Store.key(family), Store.field(labels), by)
      end

      def set(family, labels, value)
        @pipeline.call('HSET', Store.key(family), Store.field(labels), value)
      end

      def observe(family, labels, value, buckets)
        bound = buckets.find { |candidate| value <= candidate } || '+Inf'
        @pipeline.call('HINCRBY', Store.key("#{family}:bucket"), Store.field(labels + [bound.to_s]), 1)
        @pipeline.call('HINCRBYFLOAT', Store.key("#{family}:sum"), Store.field(labels), value)
      end
    end

    class << self
      # Prefixed to every key. Empty in the app; the test suite gives each parallel worker its
      # own so workers sharing a Redis do not count each other's events.
      attr_writer :namespace

      def namespace
        @namespace.to_s
      end

      def write
        ::Sidekiq.redis { |redis| redis.pipelined { |pipeline| yield Writer.new(pipeline) } }
      end

      # { [label values] => number } for one family.
      def read(family)
        raw = ::Sidekiq.redis { |redis| redis.call('HGETALL', key(family)) }
        raw.to_h.to_h { |field, value| [JSON.parse(field), numeric(value)] }
      end

      def clear!
        ::Sidekiq.redis do |redis|
          keys = redis.scan('MATCH', "#{namespace}#{ROOT}:*").to_a
          redis.call('DEL', *keys) if keys.any?
        end
      end

      def key(family)
        "#{namespace}#{ROOT}:#{family}"
      end

      def field(labels)
        labels.map(&:to_s).to_json
      end

      private

      def numeric(value)
        number = value.to_f
        number == number.to_i ? number.to_i : number
      end
    end
  end
end
