module Credentials
  # Runs `health` for every enabled provider, or for one when given its id.
  class HealthCheckJob < ApplicationJob
    queue_as :default

    def perform(provider_id = nil)
      scope = CredentialProvider.enabled
      scope = scope.where(id: provider_id) if provider_id
      scope.find_each { |provider| HealthCheck.call(provider) }
    end
  end
end
