module Api
  module V1
    # The root of the token-authenticated API. Requests carry `Authorization: Bearer <token>`
    # and nothing else: no session, no cookies, so no CSRF to defend against.
    #
    # The token's holder becomes current_user (and true_user — impersonation never applies here),
    # and `can?` answers through the token, so every privilege check made on this path is limited
    # to the token's scopes. Controllers gate actions with `require_scope!`.
    #
    # Errors share one envelope — `{ "error": { "code", "message", "details" } }` — documented in
    # docs/api/openapi.yaml. Every reason a token can be refused gets the same 401, so a caller
    # cannot probe which tokens exist or why one stopped working; the reason goes to the log.
    class BaseController < ActionController::API
      include MemberVisibility

      RATE_LIMIT = 120
      MAX_PER_PAGE = 100

      before_action :authenticate_api_token!

      rate_limit to: RATE_LIMIT, within: 1.minute, name: 'api-v1', store: RateLimiting.store,
                 by: -> { "token-#{current_api_token&.id || request.remote_ip}" },
                 with: -> { render_rate_limited }

      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
      rescue_from ActionController::ParameterMissing, with: :render_bad_request

      attr_reader :current_api_token

      private

      def authenticate_api_token!
        raw = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
        token = ApiToken.lookup(raw)
        reason = token ? token.rejection_reason : :unknown_or_missing
        return accept_token(token) if reason.nil?

        Rails.logger.info("[API] refused token #{token&.id || '-'} (#{reason}) from #{request.remote_ip}")
        response.headers['WWW-Authenticate'] = 'Bearer realm="Member Zone", error="invalid_token"'
        render_error(:invalid_token, 'The access token is missing, invalid, or no longer active.',
                     status: :unauthorized)
      end

      def accept_token(token)
        @current_api_token = token
        token.record_use!(ip: request.remote_ip)
        Current.user = token.user
        Current.true_user = token.user
        Current.api_token = token
      end

      def current_user
        current_api_token&.user
      end

      def true_user
        current_user
      end

      # Administrators get no bypass through the API: a token does what its scopes say.
      def current_user_admin?
        false
      end

      def can?(privilege, topic: nil)
        topic.nil? && current_api_token.present? && current_api_token.allows?(privilege)
      end

      def require_scope!(key)
        return if can?(key)

        render_error(:insufficient_scope, "This token needs the #{key} scope, and its holder the privilege.",
                     status: :forbidden, details: { required_scope: key.to_s })
      end

      def personal_token?
        current_api_token.personal?
      end

      def render_error(code, message, status:, details: {})
        render json: { error: { code: code.to_s, message: message, details: details } }, status: status
      end

      def render_validation_errors(record)
        render_error(:validation_failed, record.errors.full_messages.to_sentence.presence || 'Validation failed.',
                     status: :unprocessable_content, details: { fields: record.errors.to_hash })
      end

      def render_not_found
        render_error(:not_found, 'Not found.', status: :not_found)
      end

      def render_bad_request(exception)
        render_error(:bad_request, exception.message, status: :bad_request)
      end

      def render_rate_limited
        response.headers['Retry-After'] = '60'
        render_error(:rate_limited, "Rate limit of #{RATE_LIMIT} requests a minute exceeded.",
                     status: :too_many_requests)
      end

      # page/per_page pagination, with the totals in `meta` and RFC 8288 links in `Link`.
      def paginate(scope)
        per_page = params.fetch(:per_page, 25).to_i.clamp(1, MAX_PER_PAGE)
        page = [params.fetch(:page, 1).to_i, 1].max
        total = scope.count
        records = scope.offset((page - 1) * per_page).limit(per_page)
        set_link_header(page, per_page, total)
        [records, { page: page, per_page: per_page, total: total }]
      end

      def set_link_header(page, per_page, total)
        last_page = [(total.to_f / per_page).ceil, 1].max
        links = { first: 1, last: last_page }
        links[:prev] = page - 1 if page > 1
        links[:next] = page + 1 if page < last_page
        response.headers['Link'] = links.map do |rel, number|
          "<#{url_for(request.query_parameters.merge(page: number, per_page: per_page, only_path: false))}>; " \
            "rel=\"#{rel}\""
        end.join(', ')
      end
    end
  end
end
