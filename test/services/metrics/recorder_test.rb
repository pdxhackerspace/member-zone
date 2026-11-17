require 'test_helper'
require 'support/metrics_test_helper'

module Metrics
  class RecorderTest < ActiveSupport::TestCase
    include MetricsTestHelper

    class QuickJob < ApplicationJob
      queue_as :default

      def perform; end
    end

    class BrokenJob < ApplicationJob
      queue_as :mailers

      def perform
        raise ArgumentError, 'nope'
      end
    end

    setup { Store.clear! }
    teardown { Store.clear! }

    test 'nothing is recorded while metrics are off' do
      with_metrics_token(nil) do
        QuickJob.perform_now
        QuickJob.perform_later
      end

      assert_empty Store.read('job_executions')
      assert_empty Store.read('jobs_enqueued')
    end

    test 'a successful job is counted, timed and stamped' do
      with_metrics_token { 2.times { QuickJob.perform_now } }

      name = QuickJob.name

      assert_equal({ [name, 'default', 'success'] => 2 }, Store.read('job_executions'))
      assert_equal({ [name, 'default', '0.1'] => 2 }, Store.read('job_duration:bucket'))
      assert_in_delta Time.current.to_f, Store.read('job_last_success').fetch([name]), 5
      assert_empty Store.read('job_failures')
    end

    test 'a failing job is counted with its exception class' do
      with_metrics_token { assert_raises(ArgumentError) { BrokenJob.perform_now } }

      name = BrokenJob.name

      assert_equal({ [name, 'mailers', 'failure'] => 1 }, Store.read('job_executions'))
      assert_equal({ [name, 'ArgumentError'] => 1 }, Store.read('job_failures'))
      assert Store.read('job_last_failure').key?([name])
    end

    test 'enqueues are counted' do
      with_metrics_token { QuickJob.perform_later }

      assert_equal({ [QuickJob.name, 'default'] => 1 }, Store.read('jobs_enqueued'))
    end

    test 'observations land in the first bucket that holds them' do
      Store.write do |writer|
        writer.observe('took', ['a'], 0.3, [0.1, 0.5, 1])
        writer.observe('took', ['a'], 0.5, [0.1, 0.5, 1])
        writer.observe('took', ['a'], 9, [0.1, 0.5, 1])
      end

      assert_equal({ ['a', '0.5'] => 2, ['a', '+Inf'] => 1 }, Store.read('took:bucket'))
      assert_in_delta 9.8, Store.read('took:sum').fetch(['a'])
    end

    test 'a request that raised is recorded with the status Rails will answer with' do
      payload = { controller: 'UsersController', action: 'show', method: 'GET',
                  exception: ['ActiveRecord::RecordNotFound', 'gone'] }

      with_metrics_token { Recorder.request_processed(payload, 0.02) }

      assert_equal({ %w[UsersController show GET 404] => 1 }, Store.read('http_requests'))
    end

    test 'a Redis failure while recording is swallowed' do
      failing = ->(*) { raise RedisClient::CannotConnectError, 'down' }

      with_metrics_token do
        with_replaced_method(Store, :write, failing) { assert_nothing_raised { QuickJob.perform_now } }
      end
    end
  end
end
