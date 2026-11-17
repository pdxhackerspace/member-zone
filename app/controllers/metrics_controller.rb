# GET /metrics — the Prometheus scrape endpoint. See docs/metrics.md.
#
# Authenticated by a single shared bearer token, METRICS_TOKEN, rather than a member's API token:
# a scraper is not a member, needs no privileges, and should not stop working when a token
# expires. No session, no cookies. Without METRICS_TOKEN the endpoint does not exist.
class MetricsController < ActionController::API
  RATE_LIMIT = 60

  # Ahead of authentication, so guesses at the token are throttled too.
  rate_limit to: RATE_LIMIT, within: 1.minute, store: RateLimiting.store,
             by: -> { request.remote_ip }, with: -> { head :too_many_requests }

  before_action :require_metrics_enabled!
  before_action :require_metrics_token!

  def show
    response.headers['Cache-Control'] = 'no-store'
    render plain: Metrics.render, content_type: Metrics::CONTENT_TYPE
  end

  private

  def require_metrics_enabled!
    head :not_found unless Metrics.enabled?
  end

  # The token is only read from the Authorization header: a query parameter would end up in
  # access logs and proxy histories.
  def require_metrics_token!
    provided = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
    return if Metrics.valid_token?(provided)

    Rails.logger.info("[Metrics] refused scrape from #{request.remote_ip}")
    response.headers['WWW-Authenticate'] = 'Bearer realm="Member Zone metrics"'
    head :unauthorized
  end
end
