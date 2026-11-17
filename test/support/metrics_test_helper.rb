# Helpers for tests of the Prometheus metrics endpoint and its recorder.
module MetricsTestHelper
  METRICS_TEST_TOKEN = 'metrics-test-token'.freeze

  def with_metrics_token(token = METRICS_TEST_TOKEN)
    original = ENV.fetch(Metrics::TOKEN_ENV, nil)
    ENV[Metrics::TOKEN_ENV] = token
    yield
  ensure
    ENV[Metrics::TOKEN_ENV] = original
  end

  # Replaces a singleton method for the length of the block (Minitest 6 ships no stub).
  def with_replaced_method(object, name, replacement)
    original = object.method(name)
    object.define_singleton_method(name, &replacement)
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  def metrics_headers(token = METRICS_TEST_TOKEN)
    { 'Authorization' => "Bearer #{token}" }
  end

  # The value of one sample line, e.g. metric_value(body, 'memberzone_members', state: 'banned_member').
  def metric_value(text, name, labels = {})
    rendered = labels.map { |key, value| %(#{key}="#{value}") }.join(',')
    line = text.lines.find { |candidate| candidate.start_with?(labels.empty? ? "#{name} " : "#{name}{#{rendered}} ") }
    line && line.split.last.to_f
  end
end
