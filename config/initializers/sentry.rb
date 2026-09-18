Sentry.init do |config|
  config.dsn = ENV['SENTRY_DSN']

  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  config.traces_sample_rate = (ENV['SENTRY_TRACES_SAMPLE_RATE'] || 0.1).to_f
  config.profiles_sample_rate = (ENV['SENTRY_PROFILES_SAMPLE_RATE'] || 0.1).to_f

  config.send_default_pii = false
  config.enabled_environments = %w[production staging]
end if ENV['SENTRY_DSN'].present?

# Exceptions the app rescues itself never reach Sentry's Rack middleware, so until now they were
# logged and nothing else. ErrorReporting.report sends them through Rails' error reporter, and
# this is what carries them the rest of the way.
#
# Deliberately not `config.rails.register_error_subscriber = true`: that forwards *every* report,
# including the ones Rails files for unhandled exceptions under
# "application.action_dispatch" — which the Rack middleware has already captured. The result is
# two Sentry issues per crash, which is why sentry-rails ships the option disabled. Subscribing
# our own filters on ErrorReporting::SOURCE instead, so only deliberate reports are forwarded.
#
# after_initialize, not inline: initializers load alphabetically, so Sentry.init above has not
# run yet when an initializer earlier in the alphabet asks whether Sentry is configured.
Rails.application.config.after_initialize do
  Rails.error.subscribe(ErrorReporting::SentrySubscriber.new) if Sentry.initialized?
end
