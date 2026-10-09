module Credentials
  # Asks a provider's program what it issues and caches the answer on the provider. A failed
  # call keeps the schema already cached, so one bad run does not take a working provider out
  # of service; the error is recorded for the admin to see.
  class Describe
    def self.call(provider)
      new(provider).call
    end

    def initialize(provider)
      @provider = provider
    end

    def call
      outcome = Invocation.call(@provider, 'describe') { |stdout| Protocol.describe(stdout) }
      if outcome.ok?
        @provider.update_columns(schema: outcome.value, schema_fetched_at: Time.current, schema_error: nil,
                                 updated_at: Time.current)
      else
        @provider.update_columns(schema_error: outcome.error.to_s.truncate(1000), schema_fetched_at: Time.current,
                                 updated_at: Time.current)
      end
      outcome
    end
  end
end
