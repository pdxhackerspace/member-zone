require 'test_helper'

module Api
  module V1
    # Staff parking endpoints: /api/v1/parking/notices and /api/v1/parking/printers.
    class ParkingNoticesApiTest < ActionDispatch::IntegrationTest
      include ActionMailer::TestHelper

      setup do
        @staff = users(:three)
        grant_privileges(@staff, 'parking.manage_notices')
        @raw = issue_api_token(@staff, scopes: ['parking.manage_notices'])
        @member = users(:two)
        @original_print_data = CupsService.method(:print_data)
      end

      teardown do
        CupsService.define_singleton_method(:print_data, @original_print_data)
      end

      test 'lists notices newest first, paginated' do
        get api_v1_parking_notices_path(per_page: 2), headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :get, '/parking/notices'
        assert_equal 2, json_body['data'].size
        assert_equal ParkingNotice.count, json_body.dig('meta', 'total')
        assert_includes response.headers['Link'], 'rel="next"'
      end

      test 'filters by type, status, and member' do
        get api_v1_parking_notices_path(type: 'ticket', status: 'expired'), headers: api_headers(@raw)
        assert_equal [parking_notices(:expired_ticket).id], json_body['data'].pluck('id')

        get api_v1_parking_notices_path(member_id: users(:one).id), headers: api_headers(@raw)
        assert_equal [parking_notices(:active_permit), parking_notices(:cleared_permit)].map(&:id).sort,
                     json_body['data'].pluck('id').sort
      end

      test 'filtering by member still lists everyone on each notice' do
        notice = parking_notices(:active_permit)
        notice.replace_members!([users(:one).id, @member.id])

        get api_v1_parking_notices_path(member_id: @member.id), headers: api_headers(@raw)

        listed = json_body['data'].find { |row| row['id'] == notice.id }
        assert_equal [users(:one).id, @member.id].sort, listed['members'].pluck('id').sort
      end

      test 'a token without the scope cannot tell which notices or photos exist' do
        raw = issue_api_token(@member, scopes: ['parking.own_permits'])

        [api_v1_parking_notice_path(parking_notices(:active_permit)), api_v1_parking_notice_path(id: 0),
         api_v1_parking_notice_photo_path(parking_notices(:active_permit), 0),
         api_v1_parking_notice_photo_path(0, 0)].each do |path|
          get path, headers: api_headers(raw)
          assert_api_error :forbidden, 'insufficient_scope'
        end
      end

      test 'refuses an unknown filter value' do
        get api_v1_parking_notices_path(status: 'lost'), headers: api_headers(@raw)

        assert_api_error :bad_request, 'bad_request'
        assert_matches_spec :get, '/parking/notices'
      end

      test 'needs parking.manage_notices' do
        raw = issue_api_token(@member, scopes: ['parking.own_permits'])
        get api_v1_parking_notices_path, headers: api_headers(raw)

        assert_api_error :forbidden, 'insufficient_scope'
        assert_matches_spec :get, '/parking/notices'
      end

      test 'shows a notice with its history, without contact details' do
        get api_v1_parking_notice_path(parking_notices(:active_permit)), headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :get, '/parking/notices/{id}'
        data = json_body['data']
        assert_equal 'permit', data['notice_type']
        assert_equal [{ 'id' => users(:one).id, 'name' => users(:one).display_name }], data['members']
        assert_not_includes response.body, users(:one).email
        assert data.key?('events')
      end

      test 'issues a permit for the members named, recording the API token in its history' do
        assert_difference 'ParkingNotice.count', 1 do
          post api_v1_parking_notices_path, params: notice_params(member_ids: [@member.id]), as: :json,
                                            headers: api_headers(@raw)
        end

        assert_response :created
        assert_matches_spec :post, '/parking/notices'
        notice = ParkingNotice.find(json_body.dig('data', 'id'))
        assert_equal @staff, notice.issued_by
        assert_equal [@member], notice.members.to_a
        assert_equal @raw, raw_for(notice.events.find_by!(event_type: 'opened').api_token)
        assert json_body.dig('data', 'events', 0, 'via_api')
      end

      test 'staff may issue past the self-service limit' do
        post api_v1_parking_notices_path, params: notice_params(member_ids: [@member.id], expires_at: 60.days.from_now),
                                          as: :json, headers: api_headers(@raw)

        assert_response :created
      end

      test 'a permit for nobody is refused with field errors' do
        post api_v1_parking_notices_path, params: notice_params(member_ids: []), as: :json, headers: api_headers(@raw)

        assert_api_error :unprocessable_content, 'validation_failed'
        assert_matches_spec :post, '/parking/notices'
        assert json_body.dig('error', 'details', 'fields', 'members').present?
      end

      test 'updates fields and leaves members alone unless asked' do
        notice = parking_notices(:active_permit)
        patch api_v1_parking_notice_path(notice), params: { location: 'Laser room' }, as: :json,
                                                  headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :patch, '/parking/notices/{id}'
        assert_equal 'Laser room', notice.reload.location
        assert_equal [users(:one)], notice.members.to_a
      end

      test 'replaces members and emails the new ones' do
        notice = parking_notices(:active_permit)

        assert_difference 'QueuedMail.count', 1 do
          patch api_v1_parking_notice_path(notice), params: { member_ids: [users(:one).id, @member.id] }, as: :json,
                                                    headers: api_headers(@raw)
        end

        assert_equal [users(:one).id, @member.id].sort, notice.reload.members.ids.sort
      end

      test 'clears a notice' do
        post clear_api_v1_parking_notice_path(parking_notices(:active_permit)), headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :post, '/parking/notices/{id}/clear'
        assert_equal 'cleared', json_body.dig('data', 'status')
      end

      test 'clearing twice is a conflict' do
        post clear_api_v1_parking_notice_path(parking_notices(:cleared_permit)), headers: api_headers(@raw)

        assert_api_error :conflict, 'conflict'
        assert_matches_spec :post, '/parking/notices/{id}/clear'
      end

      test 'a notice needing staff clearance needs that scope on the token too' do
        notice = parking_notices(:active_permit)
        notice.update!(requires_admin_clearance: true)
        grant_privileges(@staff, 'parking.clear_admin_required')

        post clear_api_v1_parking_notice_path(notice), headers: api_headers(@raw)
        assert_api_error :forbidden, 'forbidden'
        assert_matches_spec :post, '/parking/notices/{id}/clear'

        raw = issue_api_token(@staff, scopes: ['parking.manage_notices', 'parking.clear_admin_required'])
        post clear_api_v1_parking_notice_path(notice), headers: api_headers(raw)
        assert_response :success
      end

      test 'an administrator token gets no administrator shortcut' do
        admin = users(:one)
        admin.update_columns(is_admin: true)
        notice = parking_notices(:expired_ticket)
        notice.update!(requires_admin_clearance: true)
        raw = issue_api_token(admin, scopes: ['parking.manage_notices'])

        post clear_api_v1_parking_notice_path(notice), headers: api_headers(raw)

        assert_api_error :forbidden, 'forbidden'
      end

      test 'adds a note' do
        post notes_api_v1_parking_notice_path(parking_notices(:active_permit)), params: { note: 'Moved' }, as: :json,
                                                                                headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :post, '/parking/notices/{id}/notes'
        assert_equal 'Moved', json_body.dig('data', 'events').last['note']
      end

      test 'a blank note is a validation error' do
        post notes_api_v1_parking_notice_path(parking_notices(:active_permit)), params: { note: ' ' }, as: :json,
                                                                                headers: api_headers(@raw)

        assert_api_error :unprocessable_content, 'validation_failed'
        assert_matches_spec :post, '/parking/notices/{id}/notes'
      end

      test 'downloads the PDF' do
        get pdf_api_v1_parking_notice_path(parking_notices(:active_permit)), headers: api_headers(@raw)

        assert_response :success
        assert_equal 'application/pdf', response.media_type
        assert_matches_spec :get, '/parking/notices/{id}/pdf'
      end

      test 'prints to a printer' do
        printer = Printer.create!(name: 'Front desk', cups_printer_name: 'front_desk')
        CupsService.define_singleton_method(:print_data) { |*_args, **_kwargs| 'front_desk-7' }

        post print_api_v1_parking_notice_path(parking_notices(:active_permit)), params: { printer_id: printer.id },
                                                                                as: :json, headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :post, '/parking/notices/{id}/print'
        assert_equal 'front_desk-7', json_body.dig('data', 'job_id')
      end

      test 'printing needs a printer, an active notice, and a working printer' do
        printer = Printer.create!(name: 'Front desk', cups_printer_name: 'front_desk')

        post print_api_v1_parking_notice_path(parking_notices(:active_permit)), headers: api_headers(@raw)
        assert_api_error :bad_request, 'bad_request'

        post print_api_v1_parking_notice_path(parking_notices(:cleared_permit)), params: { printer_id: printer.id },
                                                                                 as: :json, headers: api_headers(@raw)
        assert_api_error :conflict, 'conflict'

        CupsService.define_singleton_method(:print_data) { |*_args, **_kwargs| raise CupsService::PrintError, 'offline' }
        post print_api_v1_parking_notice_path(parking_notices(:active_permit)), params: { printer_id: printer.id },
                                                                                as: :json, headers: api_headers(@raw)
        assert_api_error :bad_gateway, 'print_failed'
        assert_matches_spec :post, '/parking/notices/{id}/print'
      end

      test 'lists printers' do
        Printer.create!(name: 'Front desk', cups_printer_name: 'front_desk', default_printer: true)
        get api_v1_parking_printers_path, headers: api_headers(@raw)

        assert_response :success
        assert_matches_spec :get, '/parking/printers'
        assert_equal 'Front desk', json_body['data'].first['name']
      end

      test 'uploads, downloads, and removes photos' do
        notice = parking_notices(:active_permit)

        post api_v1_parking_notice_photos_path(notice), params: { photos: [photo_upload] }, headers: api_headers(@raw)
        assert_response :created
        assert_matches_spec :post, '/parking/notices/{notice_id}/photos'
        photo = json_body['data'].first

        get photo['download_path'], headers: api_headers(@raw)
        assert_response :success
        assert_equal 'image/png', response.media_type

        delete api_v1_parking_notice_photo_path(notice, photo['id']), headers: api_headers(@raw)
        assert_response :no_content
        assert_not notice.reload.photos.attached?
      end

      test 'refuses files that are not images' do
        post api_v1_parking_notice_photos_path(parking_notices(:active_permit)),
             params: { photos: [fixture_file_upload('test_document.txt', 'text/plain')] }, headers: api_headers(@raw)

        assert_api_error :unprocessable_content, 'validation_failed'
        assert_matches_spec :post, '/parking/notices/{notice_id}/photos'
      end

      test 'a missing notice is not found' do
        get api_v1_parking_notice_path(id: 0), headers: api_headers(@raw)

        assert_api_error :not_found, 'not_found'
        assert_matches_spec :get, '/parking/notices/{id}'
      end

      private

      def notice_params(**overrides)
        { notice_type: 'permit', description: 'Bookshelf', location: 'Woodshop',
          expires_at: 3.days.from_now.iso8601 }.merge(overrides)
      end

      def photo_upload
        fixture_file_upload('parking_photo.png', 'image/png')
      end

      def raw_for(token)
        token && ApiToken.find_by(token_digest: ApiToken.digest(@raw)) == token ? @raw : nil
      end
    end
  end
end
