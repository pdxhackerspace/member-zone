module Credentials
  # Runs a provider's `health` action and records the result on the provider. Returns the
  # resulting status, one of CredentialProvider::HEALTH_STATUSES.
  class HealthCheck
    def self.call(provider)
      new(provider).call
    end

    def initialize(provider)
      @provider = provider
    end

    def call
      outcome = Invocation.call(@provider, 'health') { |stdout| Protocol.health(stdout) }
      status, message = interpret(outcome)
      @provider.record_health!(status, message)
      status
    end

    private

    def interpret(outcome)
      return ['not_configured', outcome.error] if outcome.not_configured
      return ['unhealthy', outcome.error] unless outcome.ok?

      report = outcome.value
      [report[:ok] ? 'healthy' : 'unhealthy', report[:message]]
    end
  end
end
