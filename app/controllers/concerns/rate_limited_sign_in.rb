# SPDX-FileCopyrightText: 2025 John Romkey
#
# SPDX-License-Identifier: CC0-1.0

# Rate limiting for the unauthenticated endpoints: password sign-in, keyfob PIN entry, and
# "email me a login link". Anyone on the internet can reach all of them, each one either checks a
# credential or sends mail, and none of them was limited before.
#
# Two things shape the numbers below.
#
# The limits are per IP, and a makerspace sits behind one public address, so every member signing
# in shares a counter. A limit tight enough to stop a patient attacker would lock out the space
# on a busy evening. The counters are therefore set generously, and the real defence against
# guessing a specific credential is elsewhere — RfidWebhookService discards a scan after five
# wrong PINs, whatever address they came from. What the limits stop is the scripted case: the
# thousands of attempts per minute that a script needs and a room full of people never makes.
#
# Exceeding a limit redirects with a flash rather than rendering Rails' bare 429, because these
# are pages a member is looking at. The one exception is the keyfob poll, which answers JSON.
module RateLimitedSignIn
  extend ActiveSupport::Concern

  TOO_MANY_ATTEMPTS = 'Too many attempts from this location. Please wait a few minutes and try again.'.freeze

  private

  def sign_in_rate_limit_exceeded
    log_rate_limit
    redirect_to login_path, alert: TOO_MANY_ATTEMPTS
  end

  def json_rate_limit_exceeded
    log_rate_limit
    render json: { status: 'rate_limited' }, status: :too_many_requests
  end

  # Worth a log line: a limit being hit is either an attack or a limit set too low, and both
  # need to be visible. Reported as well as logged, so it surfaces without anyone tailing logs.
  def log_rate_limit
    detail = "#{controller_name}##{action_name} from #{request.remote_ip}"
    Rails.logger.warn("[RateLimit] refused #{detail}")
    ErrorReporting.report_message("Sign-in rate limit exceeded on #{detail}",
                                  context: { controller: controller_name, action: action_name })
  end

  # Email typed into a sign-in form, for limits keyed to the account being attempted rather than
  # the address attempting it — that is the half a distributed attack cannot spread out. Reads
  # params directly because the strong-parameters helpers raise when the key is absent, and a
  # malformed request should be rate limited like any other, not crash on the way in.
  def submitted_email_for_rate_limit
    params.dig(:session, :email).to_s.strip.downcase.presence || 'blank'
  end
end
