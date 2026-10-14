require 'test_helper'

module Api
  module V1
    class AuthenticationTest < ActionDispatch::IntegrationTest
      setup do
        RateLimiting.reset!
        @member = users(:two)
        @token = issue_api_token(@member)
      end

      test 'a valid bearer token is accepted' do
        get api_v1_me_path, headers: api_headers(@token)

        assert_response :success
      end

      test 'the scheme is case-insensitive' do
        get api_v1_me_path, headers: { 'Authorization' => "bearer #{@token}" }

        assert_response :success
      end

      test 'a missing token is refused with a bearer challenge' do
        get api_v1_me_path

        assert_api_error :unauthorized, 'invalid_token'
        assert_equal 'Bearer realm="Member Zone", error="invalid_token"', response.headers['WWW-Authenticate']
        assert_matches_spec :get, '/me'
      end

      test 'an unknown token is refused' do
        get api_v1_me_path, headers: api_headers('mz_not-a-real-token')

        assert_api_error :unauthorized, 'invalid_token'
      end

      test 'a token in a query parameter or other header is not accepted' do
        get api_v1_me_path(token: @token)
        assert_api_error :unauthorized, 'invalid_token'

        get api_v1_me_path, headers: { 'X-Api-Token' => @token }
        assert_api_error :unauthorized, 'invalid_token'

        get api_v1_me_path, headers: { 'Authorization' => "Token #{@token}" }
        assert_api_error :unauthorized, 'invalid_token'
      end

      test 'every refused token gets the same answer' do
        bodies = refused_token_cases.map do |raw|
          get api_v1_me_path, headers: api_headers(raw)
          assert_response :unauthorized
          response.body
        end

        assert_equal 1, bodies.uniq.size
      end

      test 'a token works again when its member becomes active again' do
        @member.update_columns(membership_state: 'inactive_member')
        get api_v1_me_path, headers: api_headers(@token)
        assert_api_error :unauthorized, 'invalid_token'

        @member.update_columns(membership_state: 'current_member')
        get api_v1_me_path, headers: api_headers(@token)
        assert_response :success
      end

      test 'an extended token works again with the same secret' do
        token = ApiToken.authenticate(@token)
        token.update_columns(expires_at: 1.day.ago)
        get api_v1_me_path, headers: api_headers(@token)
        assert_response :unauthorized

        token.extend!(by: @member)
        get api_v1_me_path, headers: api_headers(@token)
        assert_response :success
      end

      test 'a signed-in browser session does not authenticate the API' do
        original = Rails.application.config.x.local_auth.enabled
        Rails.application.config.x.local_auth.enabled = true
        sign_in_as_plain_member
        get api_v1_me_path
        Rails.application.config.x.local_auth.enabled = original

        assert_api_error :unauthorized, 'invalid_token'
      end

      test 'use is recorded' do
        get api_v1_me_path, headers: api_headers(@token)
        token = ApiToken.find_by(token_digest: ApiToken.digest(@token))

        assert_not_nil token.last_used_at
        assert_equal '127.0.0.1', token.last_used_ip
      end

      test 'unknown API paths answer in the error envelope' do
        get '/api/v1/nothing/here', headers: api_headers(@token)

        assert_api_error :not_found, 'not_found'
      end

      test 'requests past the rate limit are refused' do
        BaseController::RATE_LIMIT.times { get api_v1_me_path, headers: api_headers(@token) }
        assert_response :success

        get api_v1_me_path, headers: api_headers(@token)
        assert_api_error :too_many_requests, 'rate_limited'
        assert_equal '60', response.headers['Retry-After']
      end

      test 'requests without a valid token are rate limited by address' do
        BaseController::ADDRESS_RATE_LIMIT.times { get api_v1_me_path, headers: api_headers('mz_guess') }
        assert_api_error :unauthorized, 'invalid_token'

        get api_v1_me_path, headers: api_headers('mz_guess')
        assert_api_error :too_many_requests, 'rate_limited'
      end

      private

      def refused_token_cases
        suspended = ApiToken.create!(user: @member, created_by: @member, name: 'S')
        suspended.suspend!(by: @member)
        revoked = ApiToken.create!(user: @member, created_by: @member, name: 'R')
        revoked.revoke!(by: @member)
        expired = ApiToken.create!(user: @member, created_by: @member, name: 'E')
        expired.update_columns(expires_at: 1.minute.ago)
        lapsed_holder = users(:three)
        inactive = ApiToken.create!(user: lapsed_holder, created_by: lapsed_holder, name: 'I')
        lapsed_holder.update_columns(membership_state: 'inactive_member')

        ['mz_unknown', suspended.token, revoked.token, expired.token, inactive.token]
      end
    end
  end
end
