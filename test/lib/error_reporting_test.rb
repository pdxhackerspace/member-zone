require 'test_helper'

class ErrorReportingTest < ActiveSupport::TestCase
  test 'a reported exception reaches the error reporter as handled' do
    error = ArgumentError.new('something went sideways')

    report = assert_error_reported(ArgumentError) do
      ErrorReporting.report(error, context: { webhook: 'kofi' })
    end

    assert_equal 'something went sideways', report.error.message
    assert_predicate report, :handled?
    assert_equal :error, report.severity
    assert_equal 'kofi', report.context[:webhook]
  end

  # The source is what keeps these apart from the reports Rails files for unhandled exceptions,
  # which Sentry's middleware has already captured.
  test 'reports carry the source the Sentry subscriber filters on' do
    report = assert_error_reported(StandardError) { ErrorReporting.report(StandardError.new('x')) }

    assert_equal ErrorReporting::SOURCE, report.source
  end

  test 'severity can be lowered for something not worth waking anyone' do
    report = assert_error_reported(StandardError) do
      ErrorReporting.report(StandardError.new('x'), severity: :warning)
    end

    assert_equal :warning, report.severity
  end

  test 'a message with no exception is reported as a recognisable error' do
    report = assert_error_reported(ErrorReporting::MemberZoneError) do
      ErrorReporting.report_message('RECHARGE_WEBHOOK_SECRET is not configured')
    end

    assert_equal 'RECHARGE_WEBHOOK_SECRET is not configured', report.error.message
    assert_equal :warning, report.severity, 'a bare message defaults to a warning'
  end

  test 'reporting does not raise when Sentry is not configured' do
    assert_nothing_raised do
      ErrorReporting.report(StandardError.new('no DSN in the test environment'))
    end
  end

  class SentrySubscriberTest < ActiveSupport::TestCase
    setup do
      @captured = []
      @subscriber = ErrorReporting::SentrySubscriber.new
    end

    test 'forwards a deliberate report to Sentry' do
      with_captured_sentry do
        @subscriber.report(ArgumentError.new('boom'), handled: true, severity: :error,
                                                      context: { webhook: 'recharge' },
                                                      source: ErrorReporting::SOURCE)
      end

      assert_equal 1, @captured.size
      assert_equal 'boom', @captured.first[:error].message
      assert_equal :error, @captured.first[:options][:level]
      assert_equal({ webhook: 'recharge' }, @captured.first[:options][:contexts][:member_zone])
    end

    # Rails reports unhandled request exceptions under this source, and Sentry's Rack middleware
    # has already captured those. Forwarding them would file two issues for one crash.
    test 'ignores the reports Rails makes for unhandled exceptions' do
      with_captured_sentry do
        @subscriber.report(ArgumentError.new('boom'), handled: false, severity: :error,
                                                      context: {}, source: 'application.action_dispatch')
      end

      assert_empty @captured
    end

    test 'ignores reports with no source at all' do
      with_captured_sentry do
        @subscriber.report(ArgumentError.new('boom'), handled: true, severity: :error, context: {})
      end

      assert_empty @captured
    end

    private

    def with_captured_sentry
      captured = @captured
      original = Sentry.method(:capture_exception)
      Sentry.define_singleton_method(:capture_exception) do |error, **options|
        captured << { error: error, options: options }
        nil
      end
      yield
    ensure
      Sentry.define_singleton_method(:capture_exception, original)
    end
  end
end
