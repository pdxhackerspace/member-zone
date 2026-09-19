# SPDX-FileCopyrightText: 2025 John Romkey
#
# SPDX-License-Identifier: CC0-1.0

# Reporting for exceptions the app catches on purpose.
#
# The three Sentry gems have been installed all along, but nothing ever called them, so Sentry
# only ever saw exceptions that escaped all the way out to the Rack middleware. Everything the
# app rescued itself — a webhook payload that would not parse, an Authentik sync that failed
# halfway, a sign-in that blew up — was written to the log and forgotten. Those are exactly the
# failures nobody is watching for, because nothing breaks visibly when they happen.
#
# Call sites go through Rails' error reporter rather than Sentry directly. That keeps them free
# of any particular vendor, and it means tests can assert a failure was reported using
# +assert_error_reported+ instead of stubbing an HTTP client.
#
# The +source+ is what keeps this from doubling up. Sentry's Rack middleware already captures
# unhandled exceptions, and Rails separately reports those same exceptions to the error reporter
# as "application.action_dispatch" — so subscribing Sentry to everything would file two issues
# for one crash. That is why sentry-rails ships +register_error_subscriber+ turned off. The
# subscriber in config/initializers/sentry.rb forwards only reports carrying this source, which
# are by definition the deliberate ones.
module ErrorReporting
  SOURCE = 'member_zone'.freeze

  class << self
    # Records an exception the caller has already decided to swallow.
    #
    #   rescue StandardError => e
    #     ErrorReporting.report(e, context: { webhook: 'recharge', topic: topic })
    #     head :internal_server_error
    #   end
    #
    # Pass anything in +context+ that would be needed to work out what happened without the
    # original request in hand. Keep personal data out of it; +send_default_pii+ is off and
    # this bypasses that setting.
    def report(error, context: {}, severity: :error)
      Rails.error.report(error, handled: true, severity: severity, source: SOURCE, context: context)
    end

    # Reports a problem that is not an exception — a webhook refused for a bad signature, a
    # secret that is not configured — so that conditions worth alerting on do not need someone
    # to raise an exception just to be seen.
    def report_message(message, context: {}, severity: :warning)
      report(MemberZoneError.new(message), context: context, severity: severity)
    end
  end

  # Carries a message with no underlying exception. Named so it is obvious in Sentry that the
  # app reported this on purpose rather than crashing.
  class MemberZoneError < StandardError; end

  # Forwards deliberate reports to Sentry. Registered in config/initializers/sentry.rb, and only
  # when Sentry is actually configured.
  class SentrySubscriber
    # Rails calls this for every report; anything the app did not send through
    # ErrorReporting.report belongs to Rails itself and Sentry has already seen it.
    def report(error, handled:, severity:, context:, source: nil)
      return unless source == SOURCE

      Sentry.capture_exception(
        error,
        level: severity,
        tags: { handled: handled },
        contexts: { member_zone: context.presence || {} }
      )
    end
  end
end
