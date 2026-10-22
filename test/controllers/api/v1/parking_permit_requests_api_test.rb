require 'test_helper'

module Api
  module V1
    # The kiosk flow: POST /api/v1/parking/permit_requests with a service-account token.
    class ParkingPermitRequestsApiTest < ActionDispatch::IntegrationTest
      include ActionMailer::TestHelper

      setup do
        RateLimiting.reset!
        @member = users(:one)
        admin = users(:three)
        admin.update_columns(is_admin: true)
        @kiosk = create_service_account(full_name: 'Front Door Kiosk')
        grant_privileges(@kiosk, 'parking.issue_for_members')
        @raw = issue_api_token(@kiosk, created_by: admin, name: 'Front door kiosk',
                                       scopes: ['parking.issue_for_members'])
        @token = ApiToken.find_by(token_digest: ApiToken.digest(@raw))
        @original_print_data = CupsService.method(:print_data)
        @printed_to = []
        printed_to = @printed_to
        CupsService.define_singleton_method(:print_data) do |_pdf, printer_name, **_kwargs|
          printed_to << printer_name
          "#{printer_name}-1"
        end
      end

      teardown do
        CupsService.define_singleton_method(:print_data, @original_print_data)
      end

      test 'refuses a request without a token' do
        assert_no_difference %w[ParkingNotice.count ParkingPermitLink.count] do
          post api_v1_parking_permit_requests_path, params: { rfid: 'RFID001', mode: 'blank' }, as: :json
        end

        assert_api_error :unauthorized, 'invalid_token'
        assert_matches_spec :post, '/parking/permit_requests'
      end

      test 'refuses a suspended token, and one whose service account is deactivated' do
        @token.suspend!(by: users(:three))
        post api_v1_parking_permit_requests_path, params: { rfid: 'RFID001', mode: 'blank' }, as: :json,
                                                  headers: api_headers(@raw)
        assert_api_error :unauthorized, 'invalid_token'

        @token.resume!(by: users(:three))
        @kiosk.update_columns(active: false)
        post api_v1_parking_permit_requests_path, params: { rfid: 'RFID001', mode: 'blank' }, as: :json,
                                                  headers: api_headers(@raw)
        assert_api_error :unauthorized, 'invalid_token'
      end

      test 'needs parking.issue_for_members' do
        raw = issue_api_token(@member, scopes: ['parking.own_permits'])
        post api_v1_parking_permit_requests_path, params: { rfid: 'RFID001', mode: 'blank' }, as: :json,
                                                  headers: api_headers(raw)

        assert_api_error :forbidden, 'insufficient_scope'
        assert_matches_spec :post, '/parking/permit_requests'
      end

      test 'link mode emails a form link and creates no permit yet' do
        assert_no_difference 'ParkingNotice.count' do
          assert_enqueued_emails 1 do
            request_permit(rfid: 'RFID001', mode: 'link')
          end
        end

        assert_response :created
        assert_matches_spec :post, '/parking/permit_requests'
        link = ParkingPermitLink.last
        assert_equal @member, link.user
        assert link.create_permit?
        assert_equal @token, link.api_token
        assert_in_delta 12.hours.from_now, link.expires_at, 5.seconds

        data = json_body['data']
        assert_equal 'link', data['mode']
        assert_equal @member.display_name, data.dig('member', 'name')
        assert data['email_sent']
        assert_nil data['permit']
        assert_not response.body.include?('/parking_permit/'), 'the form link must only go to the member'
      end

      test 'blank mode issues a two-week permit awaiting details' do
        assert_difference 'ParkingNotice.count', 1 do
          assert_enqueued_emails 1 do
            request_permit(rfid: 'RFID001', mode: 'blank')
          end
        end

        assert_response :created
        assert_matches_spec :post, '/parking/permit_requests'
        notice = ParkingNotice.order(:id).last
        assert notice.permit?
        assert notice.awaiting_details?
        assert_equal [@member], notice.members.to_a
        assert_equal @token, notice.api_token
        assert_in_delta 2.weeks.from_now, notice.expires_at, 5.seconds
        assert_equal 'Blank permit issued by Front door kiosk.', notice.events.find_by(event_type: 'note').note
        assert ParkingPermitLink.exists?(parking_notice: notice, purpose: 'complete_permit', api_token: @token)
        assert_equal notice.id, json_body.dig('data', 'permit', 'id')
      end

      test 'link mode journals the emailed form on the member' do
        request_permit(rfid: 'RFID001', mode: 'link')

        entry = Journal.where(user: @member, action: 'parking_permit_link_sent').last
        assert_equal ParkingPermitLink.last.id, entry.changes_json.dig('parking_permit_link', 'id')
        assert_equal 'Front door kiosk', entry.changes_json.dig('parking_permit_link', 'api_token', 'name')
      end

      test 'blank mode journals the permit, naming the device token' do
        request_permit(rfid: 'RFID001', mode: 'blank')

        entry = Journal.where(user: @member, action: 'parking_permit_issued').last
        assert_equal ParkingNotice.order(:id).last.id, entry.changes_json.dig('parking_notice', 'id')
        assert_equal({ 'id' => @token.id, 'name' => 'Front door kiosk' },
                     entry.changes_json.dig('parking_notice', 'api_token'))
      end

      test 'print: true prints the blank permit on the default printer' do
        Printer.create!(name: 'Back room', cups_printer_name: 'back_room')
        default = Printer.create!(name: 'Front desk', cups_printer_name: 'front_desk', default_printer: true)

        request_permit(rfid: 'RFID001', mode: 'blank', print: true)

        assert_response :created
        assert_matches_spec :post, '/parking/permit_requests'
        assert_equal ['front_desk'], @printed_to
        assert_equal({ 'printer_id' => default.id, 'printer_name' => 'Front desk', 'job_id' => 'front_desk-1',
                       'error' => nil }, json_body.dig('data', 'print'))
      end

      test 'printer_id prints on that printer' do
        Printer.create!(name: 'Front desk', cups_printer_name: 'front_desk', default_printer: true)
        back = Printer.create!(name: 'Back room', cups_printer_name: 'back_room')

        request_permit(rfid: 'RFID001', mode: 'blank', printer_id: back.id)

        assert_response :created
        assert_equal ['back_room'], @printed_to
        assert_equal back.id, json_body.dig('data', 'print', 'printer_id')
      end

      test 'without print or printer_id nothing is printed' do
        Printer.create!(name: 'Front desk', cups_printer_name: 'front_desk', default_printer: true)
        request_permit(rfid: 'RFID001', mode: 'blank')

        assert_response :created
        assert_empty @printed_to
        assert_nil json_body.dig('data', 'print')
      end

      test 'an unknown printer or no printer at all refuses before issuing anything' do
        assert_no_difference 'ParkingNotice.count' do
          request_permit(rfid: 'RFID001', mode: 'blank', printer_id: 0)
          assert_api_error :not_found, 'not_found'

          request_permit(rfid: 'RFID001', mode: 'blank', print: true)
          assert_api_error :conflict, 'conflict'
          assert_matches_spec :post, '/parking/permit_requests'
        end
      end

      test 'link mode cannot print, since there is no permit yet' do
        Printer.create!(name: 'Front desk', cups_printer_name: 'front_desk', default_printer: true)

        assert_no_enqueued_emails do
          request_permit(rfid: 'RFID001', mode: 'link', print: true)
        end
        assert_api_error :bad_request, 'bad_request'
      end

      test 'a printer that refuses the job leaves the permit issued and says why' do
        Printer.create!(name: 'Front desk', cups_printer_name: 'front_desk', default_printer: true)
        CupsService.define_singleton_method(:print_data) { |*_args, **_kwargs| raise CupsService::PrintError, 'offline' }

        assert_difference 'ParkingNotice.count', 1 do
          request_permit(rfid: 'RFID001', mode: 'blank', print: true)
        end

        assert_response :created
        assert_matches_spec :post, '/parking/permit_requests'
        assert_nil json_body.dig('data', 'print', 'job_id')
        assert_equal 'offline', json_body.dig('data', 'print', 'error')
      end

      test 'the kiosk can list printers' do
        Printer.create!(name: 'Front desk', cups_printer_name: 'front_desk', default_printer: true)
        get api_v1_parking_printers_path, headers: api_headers(@raw)

        assert_response :success
        assert_equal ['Front desk'], json_body['data'].pluck('name')
      end

      test 'finds the member by username or email' do
        request_permit(username: @member.username, mode: 'link')
        assert_response :created
        assert_equal @member, ParkingPermitLink.last.user

        request_permit(email: @member.email, mode: 'link')
        assert_response :created
        assert_equal @member, ParkingPermitLink.last.user
      end

      test 'finds the member by slack uid on the user or linked slack account' do
        @member.update_columns(slack_id: 'UKIOSKUSER')
        request_permit(slack_uid: 'UKIOSKUSER', mode: 'link')
        assert_response :created
        assert_equal @member, ParkingPermitLink.last.user

        @member.update_columns(slack_id: nil)
        slack_user = slack_users(:with_dept)
        slack_user.update!(user: @member)
        request_permit(slack_uid: slack_user.slack_id, mode: 'link')
        assert_response :created
        assert_equal @member, ParkingPermitLink.last.user
      end

      test 'an unknown member is not found' do
        request_permit(rfid: 'NOPE', mode: 'blank')

        assert_api_error :not_found, 'not_found'
        assert_matches_spec :post, '/parking/permit_requests'
      end

      test 'a request without a member or with an unknown mode is a bad request' do
        request_permit(mode: 'blank')
        assert_api_error :bad_request, 'bad_request'

        request_permit(rfid: 'RFID001', mode: 'sticker')
        assert_api_error :bad_request, 'bad_request'
        assert_matches_spec :post, '/parking/permit_requests'
      end

      test 'a banned member is refused' do
        @member.ban!
        request_permit(rfid: 'RFID001', mode: 'blank')

        assert_api_error :unprocessable_content, 'ineligible_member'
        assert_matches_spec :post, '/parking/permit_requests'
      end

      test 'the kiosk cannot reach the staff parking endpoints' do
        get api_v1_parking_notices_path, headers: api_headers(@raw)

        assert_api_error :forbidden, 'insufficient_scope'
      end

      private

      def request_permit(**body)
        post api_v1_parking_permit_requests_path, params: body, as: :json, headers: api_headers(@raw)
      end
    end
  end
end
