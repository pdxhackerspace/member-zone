require 'test_helper'

module Credentials
  class HealthCheckTest < ActiveSupport::TestCase
    test 'a healthy program is recorded healthy' do
      provider = create_credential_provider(health: nil)

      assert_equal 'healthy', HealthCheck.call(provider)

      provider.reload
      assert_equal 'healthy', provider.health_status
      assert_equal 'all good', provider.health_message
      assert_not_nil provider.last_healthy_at
      assert_not_nil provider.last_health_check_at
    end

    test 'ok false is unhealthy and keeps the message' do
      provider = create_credential_provider(env: { UNHEALTHY: '1' })

      assert_equal 'unhealthy', HealthCheck.call(provider)
      assert_equal 'upstream is down', provider.reload.health_message
    end

    test 'environment values in a healthy report are blanked out before they are stored' do
      provider = create_credential_provider(env: { API_KEY: 'live-key-0123456789', HEALTH_ECHOES_KEY: '1' })

      assert_equal 'healthy', HealthCheck.call(provider)
      assert_equal 'checked with [REDACTED]', provider.reload.health_message
    end

    test 'a failing exit is unhealthy' do
      provider = create_credential_provider(script: 'exits_3.sh')

      assert_equal 'unhealthy', HealthCheck.call(provider)
      assert_equal 'Exited with status 3', provider.reload.health_message
    end

    test 'exit 2 is not configured' do
      provider = create_credential_provider(script: 'not_configured.sh')

      assert_equal 'not_configured', HealthCheck.call(provider)
      assert_equal 'not_configured', provider.reload.health_status
    end

    test 'malformed output is unhealthy' do
      # echo_env.rb answers every action with JSON that has no "ok".
      provider = create_credential_provider(script: 'echo_env.rb', describe: false)

      assert_equal 'unhealthy', HealthCheck.call(provider)
      assert_match(/Invalid health output/, provider.reload.health_message)
    end

    test 'recovery sets last_healthy_at again' do
      provider = create_credential_provider(env: { UNHEALTHY: '1' })
      HealthCheck.call(provider)
      assert_equal 'unhealthy', provider.reload.health_status

      provider.update!(environment_variables: "STATE_DIR=#{credential_state_dir}")
      assert_equal 'healthy', HealthCheck.call(provider)
    end

    test 'records a health run' do
      provider = create_credential_provider
      assert_difference -> { provider.credential_runs.where(action: 'health').count } => 1 do
        HealthCheck.call(provider)
      end
    end

    test 'a program that cannot be run is unhealthy' do
      provider = create_credential_provider
      provider.update_columns(script_path: '/nonexistent/credentials/nope.sh')

      assert_equal 'unhealthy', HealthCheck.call(provider)
    end
  end
end
