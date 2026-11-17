require 'test_helper'
require 'support/metrics_test_helper'

class MetricsControllerTest < ActionDispatch::IntegrationTest
  include MetricsTestHelper

  setup { Metrics::Store.clear! }
  teardown { Metrics::Store.clear! }

  test 'the endpoint does not exist until a token is configured' do
    with_metrics_token(nil) do
      get metrics_path, headers: metrics_headers

      assert_response :not_found
    end
  end

  test 'a blank token leaves the endpoint off' do
    with_metrics_token('   ') do
      get metrics_path, headers: metrics_headers('   ')

      assert_response :not_found
    end
  end

  test 'a request without a token is refused with a bearer challenge' do
    with_metrics_token do
      get metrics_path

      assert_response :unauthorized
      assert_equal 'Bearer realm="Member Zone metrics"', response.headers['WWW-Authenticate']
      assert_empty response.body
    end
  end

  test 'a wrong token is refused' do
    with_metrics_token do
      get metrics_path, headers: metrics_headers('not-the-token')

      assert_response :unauthorized
    end
  end

  test 'a token in a query parameter is not accepted' do
    with_metrics_token do
      get metrics_path(token: METRICS_TEST_TOKEN)

      assert_response :unauthorized
    end
  end

  test 'a signed-in administrator without the token is still refused' do
    with_metrics_token do
      with_local_auth do
        sign_in_as_admin
        get metrics_path

        assert_response :unauthorized
      end
    end
  end

  test 'the right token gets the exposition' do
    with_metrics_token do
      get metrics_path, headers: metrics_headers

      assert_response :success
      assert_equal 'text/plain; version=0.0.4; charset=utf-8', response.headers['Content-Type']
      assert_equal 'no-store', response.headers['Cache-Control']
      assert_includes response.body, '# TYPE memberzone_build_info gauge'
      assert_includes response.body, '# TYPE memberzone_members gauge'
      assert_includes response.body, '# TYPE sidekiq_enqueued_jobs gauge'
    end
  end

  test 'the scheme is case-insensitive' do
    with_metrics_token do
      get metrics_path, headers: { 'Authorization' => "bearer #{METRICS_TEST_TOKEN}" }

      assert_response :success
    end
  end

  test 'every collector reports success' do
    with_metrics_token do
      get metrics_path, headers: metrics_headers

      Metrics::COLLECTORS.each_key do |name|
        assert_equal 1.0, metric_value(response.body, 'memberzone_scrape_collector_success', collector: name),
                     "#{name} collector failed"
      end
    end
  end

  test 'every sample line is well formed' do
    with_metrics_token do
      get metrics_path, headers: metrics_headers

      sample = /\A[a-z_][a-z0-9_]*(\{([a-z_]+="(\\.|[^"\\])*",?)+\})? -?[0-9.e+-]+\z/
      response.body.each_line(chomp: true) do |line|
        next if line.start_with?('# HELP ', '# TYPE ')

        assert_match sample, line
      end
    end
  end

  test 'requests are counted and show up on a later scrape' do
    with_metrics_token do
      get metrics_path, headers: metrics_headers
      get metrics_path, headers: metrics_headers

      labels = { controller: 'MetricsController', action: 'show', method: 'GET', status: '200' }

      assert_equal 1.0, metric_value(response.body, 'memberzone_http_requests_total', labels)
      assert_equal 1.0, metric_value(response.body, 'memberzone_http_request_duration_seconds_count',
                                     controller: 'MetricsController', action: 'show')
    end
  end

  test 'scrapes are rate limited per address' do
    with_metrics_token do
      MetricsController::RATE_LIMIT.times { get metrics_path }
      get metrics_path, headers: metrics_headers

      assert_response :too_many_requests
    end
  end
end
