require 'test_helper'

module Api
  module V1
    class MeControllerTest < ActionDispatch::IntegrationTest
      test 'describes a personal token' do
        member = users(:two)
        raw = issue_api_token(member, scopes: ['parking.own_permits'])
        get api_v1_me_path, headers: api_headers(raw)

        assert_response :success
        assert_matches_spec :get, '/me'
        data = json_body['data']
        assert_equal 'personal', data['kind']
        assert_equal ['parking.own_permits'], data['scopes']
        assert_equal ['parking.own_permits'], data['effective_scopes']
        assert_equal raw.last(4), data['hint']
        assert_equal member.id, data.dig('holder', 'id')
        assert_not_includes response.body, raw
      end

      test 'effective scopes leave out privileges the holder has lost' do
        member = users(:two)
        topic = grant_privileges(member, 'api.users.search')
        raw = issue_api_token(member, scopes: ['api.users.search'])
        Training.where(trainee: member, training_topic: topic).destroy_all

        get api_v1_me_path, headers: api_headers(raw)

        assert_equal ['api.users.search'], json_body.dig('data', 'scopes')
        assert_empty json_body.dig('data', 'effective_scopes')
      end

      test 'describes a service token' do
        admin = users(:one)
        admin.update_columns(is_admin: true)
        kiosk = create_service_account(full_name: 'Front Desk Kiosk')
        raw = issue_api_token(kiosk, created_by: admin)
        get api_v1_me_path, headers: api_headers(raw)

        assert_response :success
        assert_matches_spec :get, '/me'
        assert_equal 'service', json_body.dig('data', 'kind')
        assert_equal 'Front Desk Kiosk', json_body.dig('data', 'holder', 'name')
      end
    end
  end
end
