require 'test_helper'

module Api
  module V1
    class MembersControllerTest < ActionDispatch::IntegrationTest
      setup do
        @searcher = users(:two)
        grant_privileges(@searcher, 'api.users.search')
        @raw = issue_api_token(@searcher, scopes: ['api.users.search'])
      end

      test 'finds members by part of a name' do
        get api_v1_members_path(q: 'user one'), headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :get, '/members'
        assert_equal [users(:one).id], json_body['data'].pluck('id')
        assert_equal 'user1@example.com', json_body['data'].first['email']
      end

      test 'finds members by a whole email address' do
        get api_v1_members_path(q: 'beta@example.com'), headers: api_headers(@raw)

        assert_equal [users(:three).id], json_body['data'].pluck('id')
      end

      test 'treats LIKE wildcards literally' do
        get api_v1_members_path(q: '%'), headers: api_headers(@raw)

        assert_response :success
        assert_empty json_body['data']
      end

      test 'leaves out private profiles' do
        users(:one).update_columns(profile_visibility: 'private')
        get api_v1_members_path(q: 'user one'), headers: api_headers(@raw)

        assert_empty json_body['data']
      end

      test 'includes private profiles when the token may view them' do
        users(:one).update_columns(profile_visibility: 'private')
        grant_privileges(@searcher, 'members.view_profile')
        raw = issue_api_token(@searcher, scopes: ['api.users.search', 'members.view_profile'])
        get api_v1_members_path(q: 'user one'), headers: api_headers(raw)

        assert_equal [users(:one).id], json_body['data'].pluck('id')
      end

      test 'leaves out service accounts' do
        create_service_account(full_name: 'Example Kiosk')
        get api_v1_members_path(q: 'example kiosk'), headers: api_headers(@raw)

        assert_empty json_body['data']
      end

      test 'requires q' do
        get api_v1_members_path, headers: api_headers(@raw)

        assert_api_error :bad_request, 'bad_request'
        assert_matches_spec :get, '/members'
      end

      test 'requires the scope' do
        raw = issue_api_token(@searcher)
        get api_v1_members_path(q: 'user'), headers: api_headers(raw)

        assert_api_error :forbidden, 'insufficient_scope'
        assert_equal 'api.users.search', json_body.dig('error', 'details', 'required_scope')
        assert_matches_spec :get, '/members'
      end

      test 'requires the holder to still hold the privilege' do
        Training.where(trainee: @searcher).destroy_all
        get api_v1_members_path(q: 'user'), headers: api_headers(@raw)

        assert_api_error :forbidden, 'insufficient_scope'
      end

      test 'an administrator token without the scope is refused' do
        admin = users(:one)
        admin.update_columns(is_admin: true)
        raw = issue_api_token(admin)
        get api_v1_members_path(q: 'user'), headers: api_headers(raw)

        assert_api_error :forbidden, 'insufficient_scope'
      end

      test 'shows one member' do
        get api_v1_member_path(id: users(:three).id), headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :get, '/members/{id}'
        assert_equal 'betauser', json_body.dig('data', 'username')
      end

      test 'a hidden member is not found' do
        users(:three).update_columns(profile_visibility: 'private')
        get api_v1_member_path(id: users(:three).id), headers: api_headers(@raw)

        assert_api_error :not_found, 'not_found'
        assert_matches_spec :get, '/members/{id}'
      end

      test 'a missing member is not found' do
        get api_v1_member_path(id: 0), headers: api_headers(@raw)

        assert_api_error :not_found, 'not_found'
      end
    end
  end
end
