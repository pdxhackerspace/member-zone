require 'test_helper'

module Api
  module V1
    # Self-service parking endpoints: /api/v1/me/parking/notices.
    class OwnParkingNoticesApiTest < ActionDispatch::IntegrationTest
      setup do
        @member = users(:one)
        @raw = issue_api_token(@member, scopes: ['parking.own_permits'])
        @original_print_data = CupsService.method(:print_data)
      end

      teardown do
        CupsService.define_singleton_method(:print_data, @original_print_data)
      end

      test 'lists only your own notices' do
        get api_v1_me_parking_notices_path, headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :get, '/me/parking/notices'
        assert_equal [parking_notices(:active_permit), parking_notices(:cleared_permit)].map(&:id).sort,
                     json_body['data'].pluck('id').sort
      end

      test 'lists everyone on each of your notices' do
        notice = parking_notices(:active_permit)
        notice.replace_members!([@member.id, users(:two).id])

        get api_v1_me_parking_notices_path, headers: api_headers(@raw)

        listed = json_body['data'].find { |row| row['id'] == notice.id }
        assert_equal [@member.id, users(:two).id].sort, listed['members'].pluck('id').sort
      end

      test 'a token without the scope cannot tell which of your notices exist' do
        raw = issue_api_token(@member)

        [api_v1_me_parking_notice_path(parking_notices(:active_permit)), api_v1_me_parking_notice_path(id: 0),
         api_v1_me_parking_notice_photo_path(parking_notices(:active_permit), 0)].each do |path|
          get path, headers: api_headers(raw)
          assert_api_error :forbidden, 'insufficient_scope'
        end
      end

      test 'filters by status' do
        get api_v1_me_parking_notices_path(status: 'active'), headers: api_headers(@raw)

        assert_equal [parking_notices(:active_permit).id], json_body['data'].pluck('id')
      end

      test "someone else's notice is not found" do
        get api_v1_me_parking_notice_path(parking_notices(:expired_ticket)), headers: api_headers(@raw)

        assert_api_error :not_found, 'not_found'
        assert_matches_spec :get, '/me/parking/notices/{id}'
      end

      test 'needs the parking.own_permits scope' do
        raw = issue_api_token(@member)
        get api_v1_me_parking_notices_path, headers: api_headers(raw)

        assert_api_error :forbidden, 'insufficient_scope'
        assert_matches_spec :get, '/me/parking/notices'
      end

      test 'service-account tokens are refused' do
        admin = users(:three)
        admin.update_columns(is_admin: true)
        kiosk = create_service_account
        grant_privileges(kiosk, 'parking.manage_notices')
        raw = issue_api_token(kiosk, created_by: admin, scopes: ['parking.manage_notices'])
        token = ApiToken.find_by(token_digest: ApiToken.digest(raw))
        token.update_columns(scopes: ['parking.own_permits'])

        get api_v1_me_parking_notices_path, headers: api_headers(raw)

        assert_api_error :forbidden, 'insufficient_scope'
      end

      test 'an inactive member cannot use it' do
        @member.update_columns(membership_state: 'inactive_member')
        get api_v1_me_parking_notices_path, headers: api_headers(@raw)

        assert_api_error :unauthorized, 'invalid_token'
      end

      test 'gives yourself a permit' do
        assert_difference 'ParkingNotice.count', 1 do
          post api_v1_me_parking_notices_path, params: permit_params, as: :json, headers: api_headers(@raw)
        end

        assert_response :created
        assert_matches_spec :post, '/me/parking/notices'
        notice = ParkingNotice.find(json_body.dig('data', 'id'))
        assert notice.permit?
        assert_equal @member, notice.issued_by
        assert_equal [@member], notice.members.to_a
      end

      test 'cannot give yourself a ticket or a long permit' do
        post api_v1_me_parking_notices_path, params: permit_params(notice_type: 'ticket'), as: :json,
                                             headers: api_headers(@raw)
        assert_equal 'permit', json_body.dig('data', 'notice_type')

        post api_v1_me_parking_notices_path, params: permit_params(expires_at: 20.days.from_now.iso8601), as: :json,
                                             headers: api_headers(@raw)
        assert_api_error :unprocessable_content, 'validation_failed'
        assert_equal ['must be within 2 weeks'], json_body.dig('error', 'details', 'fields', 'expires_at')
        assert_matches_spec :post, '/me/parking/notices'
      end

      test 'changes your permit' do
        notice = parking_notices(:active_permit)
        patch api_v1_me_parking_notice_path(notice), params: { location_detail: 'Bench C' }, as: :json,
                                                     headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :patch, '/me/parking/notices/{id}'
        assert_equal 'Bench C', notice.reload.location_detail
      end

      test 'cannot change a ticket' do
        ticket = parking_notices(:expired_ticket)
        ParkingNoticeMember.create!(parking_notice: ticket, user: @member)

        patch api_v1_me_parking_notice_path(ticket), params: { description: 'Not mine' }, as: :json,
                                                     headers: api_headers(@raw)

        assert_api_error :forbidden, 'forbidden'
        assert_matches_spec :patch, '/me/parking/notices/{id}'
      end

      test 'cannot download or print a ticket' do
        ticket = parking_notices(:expired_ticket)
        ParkingNoticeMember.create!(parking_notice: ticket, user: @member)
        printer = Printer.create!(name: 'Front desk', cups_printer_name: 'front_desk')

        get pdf_api_v1_me_parking_notice_path(ticket), headers: api_headers(@raw)
        assert_api_error :forbidden, 'forbidden'

        post print_api_v1_me_parking_notice_path(ticket), params: { printer_id: printer.id }, as: :json,
                                                          headers: api_headers(@raw)
        assert_api_error :forbidden, 'forbidden'
        assert_matches_spec :post, '/me/parking/notices/{id}/print'
      end

      test 'clears your notice' do
        post close_api_v1_me_parking_notice_path(parking_notices(:active_permit)), headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :post, '/me/parking/notices/{id}/close'
        assert parking_notices(:active_permit).reload.cleared?
      end

      test 'a notice needing staff clearance cannot be cleared, but clearance can be requested once' do
        notice = parking_notices(:active_permit)
        notice.update!(requires_admin_clearance: true)

        post close_api_v1_me_parking_notice_path(notice), headers: api_headers(@raw)
        assert_api_error :forbidden, 'forbidden'

        post request_clearance_api_v1_me_parking_notice_path(notice), headers: api_headers(@raw)
        assert_response :success
        assert_matches_spec :post, '/me/parking/notices/{id}/request_clearance'
        assert_not_nil json_body.dig('data', 'clearance_requested_at')

        post request_clearance_api_v1_me_parking_notice_path(notice), headers: api_headers(@raw)
        assert_api_error :conflict, 'conflict'
      end

      test 'adds a note' do
        post notes_api_v1_me_parking_notice_path(parking_notices(:active_permit)), params: { note: 'Glue drying' },
                                                                                   as: :json, headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :post, '/me/parking/notices/{id}/notes'
      end

      test 'downloads and prints your notice' do
        notice = parking_notices(:active_permit)
        get pdf_api_v1_me_parking_notice_path(notice), headers: api_headers(@raw)
        assert_equal 'application/pdf', response.media_type

        printer = Printer.create!(name: 'Front desk', cups_printer_name: 'front_desk')
        CupsService.define_singleton_method(:print_data) { |*_args, **_kwargs| 'job-1' }
        post print_api_v1_me_parking_notice_path(notice), params: { printer_id: printer.id }, as: :json,
                                                          headers: api_headers(@raw)
        assert_response :success
        assert_matches_spec :post, '/me/parking/notices/{id}/print'
      end

      test 'lists printers with the self-service scope' do
        get api_v1_parking_printers_path, headers: api_headers(@raw)

        assert_response :success
      end

      test 'adds and removes photos on your permit' do
        notice = parking_notices(:active_permit)
        post api_v1_me_parking_notice_photos_path(notice),
             params: { photos: [fixture_file_upload('parking_photo.png', 'image/png')] }, headers: api_headers(@raw)

        assert_response :created
        assert_matches_spec :post, '/me/parking/notices/{notice_id}/photos'
        photo_id = json_body['data'].first['id']
        assert_equal api_v1_me_parking_notice_photo_path(notice, photo_id), json_body['data'].first['download_path']

        delete api_v1_me_parking_notice_photo_path(notice, photo_id), headers: api_headers(@raw)
        assert_response :no_content
      end

      test 'cannot add photos to a ticket' do
        ticket = parking_notices(:expired_ticket)
        ParkingNoticeMember.create!(parking_notice: ticket, user: @member)

        post api_v1_me_parking_notice_photos_path(ticket),
             params: { photos: [fixture_file_upload('parking_photo.png', 'image/png')] }, headers: api_headers(@raw)

        assert_api_error :forbidden, 'forbidden'
      end

      private

      def permit_params(**overrides)
        { description: 'Bookshelf', location: 'Woodshop', expires_at: 3.days.from_now.iso8601 }.merge(overrides)
      end
    end
  end
end
