require 'test_helper'

module Credentials
  class HealthCheckJobTest < ActiveJob::TestCase
    test 'checks every enabled provider' do
      a = create_credential_provider(health: nil)
      b = create_credential_provider(health: nil, env: { UNHEALTHY: '1' })
      off = create_credential_provider(health: nil, enabled: false)

      HealthCheckJob.perform_now

      assert_equal 'healthy', a.reload.health_status
      assert_equal 'unhealthy', b.reload.health_status
      assert_equal 'unknown', off.reload.health_status
    end

    test 'can check a single provider' do
      a = create_credential_provider(health: nil)
      b = create_credential_provider(health: nil)

      HealthCheckJob.perform_now(a.id)

      assert_equal 'healthy', a.reload.health_status
      assert_equal 'unknown', b.reload.health_status
    end

    test 'an unknown id does nothing' do
      assert_nothing_raised { HealthCheckJob.perform_now(0) }
    end

    test 'goes on the default queue' do
      assert_equal 'default', HealthCheckJob.new.queue_name
    end
  end
end
