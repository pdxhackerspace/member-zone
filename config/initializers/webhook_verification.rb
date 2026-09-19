# SPDX-FileCopyrightText: 2025 John Romkey
#
# SPDX-License-Identifier: CC0-1.0

# Whether a webhook may be accepted when the secret that authenticates it is not configured.
#
# It used to be, implicitly. Every handler in WebhooksController was written as "verify the
# signature if a secret is set", so a missing or misspelled environment variable did not fail
# loudly — it turned the endpoint into an anonymous one. These endpoints create payment records,
# change membership state, and write access logs, and CSRF protection is deliberately off for all
# of them because they are machine-to-machine. So the cost of one absent variable was an open
# write path into the members table, with nothing in the logs to say so.
#
# Now a missing secret refuses the request everywhere it matters. Development and test still
# allow it, because requiring five secrets to try a webhook locally would only teach people to
# set them to "x". Set ALLOW_UNVERIFIED_WEBHOOKS explicitly to override either way.
Rails.application.config.x.webhooks = ActiveSupport::InheritableOptions.new(
  allow_unverified: ActiveModel::Type::Boolean.new.cast(
    ENV.fetch('ALLOW_UNVERIFIED_WEBHOOKS', Rails.env.local?.to_s)
  )
)

module WebhookVerification
  class << self
    # True when a handler whose secret is unset must refuse the request rather than trust it.
    def required?
      !Rails.application.config.x.webhooks.allow_unverified
    end

    # Test seam. Production changes this through ALLOW_UNVERIFIED_WEBHOOKS at boot, but a test
    # proving the closed-door behaviour has to flip it for one example without running in
    # production mode.
    def with_required(required)
      original = Rails.application.config.x.webhooks.allow_unverified
      Rails.application.config.x.webhooks.allow_unverified = !required
      yield
    ensure
      Rails.application.config.x.webhooks.allow_unverified = original
    end
  end
end
