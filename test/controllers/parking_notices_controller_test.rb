require 'test_helper'

class ParkingNoticesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV['LOCAL_AUTH_ENABLED'] = 'true'
    sign_in_as_admin
    @active_permit = parking_notices(:active_permit)
    @expired_ticket = parking_notices(:expired_ticket)
  end

  teardown do
    ENV.delete('LOCAL_AUTH_ENABLED')
  end

  # --- Index ---

  test 'index shows parking notices' do
    get parking_notices_url
    assert_response :success
    assert_select 'table'
  end

  test 'index filters by status' do
    get parking_notices_url(status: 'active')
    assert_response :success
  end

  test 'index filters by type' do
    get parking_notices_url(type: 'permit')
    assert_response :success
  end

  test 'index shows print action for active notices only' do
    printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')

    get parking_notices_url

    assert_response :success
    assert_select 'a[href=?]', print_notice_parking_notice_path(@active_permit, printer_id: printer.id)
    assert_select 'a[href^=?]', print_notice_parking_notice_path(@expired_ticket), count: 0
  end

  test 'printing an expired notice is rejected' do
    printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')

    post print_notice_parking_notice_path(@expired_ticket, printer_id: printer.id)

    assert_redirected_to parking_notice_path(@expired_ticket)
    assert_match(/cannot be printed/i, flash[:alert])
  end

  test 'show displays printer print dropdown when multiple printers exist' do
    Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')
    Printer.create!(name: 'Back Office', cups_printer_name: 'back_office')

    get parking_notice_url(@active_permit)

    assert_response :success
    assert_select '.btn-group .dropdown-toggle', text: /Print/
  end

  test 'index shows member username not display name' do
    user = @active_permit.members.first
    user.update!(slack_handle: 'parkedslack')

    get parking_notices_url

    assert_response :success
    assert_select 'td a', text: user.parking_member_label
  end

  test 'index eager loads slack_user for member labels' do
    user = @active_permit.members.first
    user.update!(slack_handle: nil)
    slack_users(:with_dept).update!(user: user)

    queries = count_slack_user_queries { get parking_notices_url }

    assert_response :success
    assert queries <= 1, "Expected at most 1 slack_users query, got #{queries}"
  end

  test 'show displays member username not display name' do
    user = @active_permit.members.first
    user.update!(slack_handle: 'showslack')

    get parking_notice_url(@active_permit)

    assert_response :success
    assert_match user.parking_member_label, response.body
    assert_no_match(/<dd>\s*#{Regexp.escape(user.display_name)}/, response.body)
  end

  test 'show eager loads slack_user for member label' do
    user = @active_permit.members.first
    user.update!(slack_handle: nil)
    slack_users(:with_dept).update!(user: user)

    queries = count_slack_user_queries { get parking_notice_url(@active_permit) }

    assert_response :success
    assert queries <= 1, "Expected at most 1 slack_users query, got #{queries}"
  end

  # --- Show ---

  test 'show displays parking notice' do
    get parking_notice_url(@active_permit)
    assert_response :success
    assert_select '.badge', text: 'Permit'
  end

  # --- New ---

  test 'new renders permit form' do
    get new_parking_notice_url(type: 'permit')
    assert_response :success
    assert_select 'input[name="parking_notice[notice_type]"][value="permit"]'
    assert_select 'input[name="create_another_permit"][value="Save and Create Another Permit"]'
    assert_select 'input[name="print_create_another_permit"][value="Save, Print and Create Another Permit"]'
    assert_expiration_quick_buttons
  end

  test 'new pre-fills permit form from params' do
    user = users(:one)

    get new_parking_notice_url(
      type: 'permit',
      parking_notice: {
        member_ids: [user.id],
        description: 'Repeat permit',
        expires_at: '2026-06-01T17:00',
        location: 'Woodshop',
        location_detail: 'South wall shelf'
      }
    )

    assert_response :success
    assert_select "input[name='parking_notice[member_ids][]'][value=?]", user.id.to_s
    assert_select 'textarea[name="parking_notice[description]"]', text: 'Repeat permit'
    assert_select 'input[name="parking_notice[expires_at]"][value="2026-06-01T17:00"]'
    assert_select 'input[name="parking_notice[location]"][value="Woodshop"]'
    assert_select 'input[name="parking_notice[location_detail]"][value="South wall shelf"]'
  end

  test 'member search shows username and slack handle not email' do
    user = users(:one)
    user.update!(slack_handle: 'searchslack')

    get new_parking_notice_url(type: 'permit')
    assert_response :success

    row = "[data-member-picker-target='result'][data-user-id='#{user.id}']"
    assert_select row, text: /#{Regexp.escape(user.username)}/
    assert_select row, text: /@searchslack/
    assert_select "#{row} .text-11", text: /#{Regexp.escape(user.email)}/
  end

  test 'member picker eager loads slack_user associations' do
    users(:one).update!(slack_handle: nil)
    users(:two).update!(slack_handle: nil)
    slack_users(:with_dept).update!(user: users(:one))
    slack_users(:with_other_dept).update!(user: users(:two))

    queries = count_slack_user_queries { get new_parking_notice_url(type: 'permit') }

    assert_response :success
    assert queries <= 1, "Expected at most 1 slack_users query, got #{queries}"
  end

  test 'new renders ticket form' do
    get new_parking_notice_url(type: 'ticket')
    assert_response :success
    assert_select 'input[name="parking_notice[notice_type]"][value="ticket"]'
    assert_select 'input[name="create_another_permit"]', false
    assert_select 'input[name="print_create_another_permit"]', false
    assert_expiration_quick_buttons
  end

  # --- Create ---

  test 'create saves a valid permit' do
    user = users(:one)
    assert_difference 'ParkingNotice.count', 1 do
      post parking_notices_url, params: {
        parking_notice: {
          notice_type: 'permit',
          member_ids: [user.id],
          description: 'Test permit',
          location: 'Woodshop',
          expires_at: 7.days.from_now
        }
      }
    end
    notice = ParkingNotice.last
    assert notice.member?(user)
    assert_redirected_to parking_notice_path(notice)
  end

  test 'create saves a permit with multiple members' do
    first = users(:one)
    second = users(:two)

    assert_difference 'ParkingNotice.count', 1 do
      post parking_notices_url, params: {
        parking_notice: {
          notice_type: 'permit',
          member_ids: [first.id, second.id],
          description: 'Shared bench',
          location: 'Woodshop',
          expires_at: 7.days.from_now
        }
      }
    end

    notice = ParkingNotice.last
    assert notice.member?(first)
    assert notice.member?(second)
  end

  test 'create can save and start another permit with matching fields' do
    user = users(:one)
    expires_at = '2026-06-01T17:00'

    assert_difference 'ParkingNotice.count', 1 do
      post parking_notices_url, params: {
        create_another_permit: 'Save and Create Another Permit',
        parking_notice: {
          notice_type: 'permit',
          member_ids: [user.id],
          description: 'Repeat permit',
          expires_at: expires_at,
          location: 'Woodshop',
          location_detail: 'South wall shelf'
        }
      }
    end

    location = URI.parse(response.location)
    redirect_params = Rack::Utils.parse_nested_query(location.query)

    assert_equal new_parking_notice_path, location.path
    assert_equal 'permit', redirect_params['type']
    assert_equal [user.id.to_s], Array(redirect_params.dig('parking_notice', 'member_ids'))
    assert_equal 'Repeat permit', redirect_params.dig('parking_notice', 'description')
    assert_equal expires_at, redirect_params.dig('parking_notice', 'expires_at')
    assert_equal 'Woodshop', redirect_params.dig('parking_notice', 'location')
    assert_equal 'South wall shelf', redirect_params.dig('parking_notice', 'location_detail')
  end

  test 'create can save print and start another permit with matching fields' do
    user = users(:one)
    printer = Printer.create!(name: 'Default Printer', cups_printer_name: 'default_printer', default_printer: true)
    expires_at = '2026-06-01T17:00'
    printed = nil
    original_print_data = CupsService.method(:print_data)

    CupsService.define_singleton_method(:print_data) do |data, cups_printer_name,
                                                        cups_printer_server:, filename:, options:|
      printed = {
        data: data,
        cups_printer_name: cups_printer_name,
        cups_printer_server: cups_printer_server,
        filename: filename,
        options: options
      }
      'default-printer-42'
    end

    begin
      assert_difference 'ParkingNotice.count', 1 do
        post parking_notices_url, params: {
          print_create_another_permit: 'Save, Print and Create Another Permit',
          parking_notice: {
            notice_type: 'permit',
            member_ids: [user.id],
            description: 'Repeat printed permit',
            expires_at: expires_at,
            location: 'Woodshop',
            location_detail: 'South wall shelf'
          }
        }
      end
    ensure
      CupsService.define_singleton_method(:print_data, original_print_data)
    end

    notice = ParkingNotice.order(:created_at).last
    location = URI.parse(response.location)
    redirect_params = Rack::Utils.parse_nested_query(location.query)

    assert_equal new_parking_notice_path, location.path
    assert_equal 'permit', redirect_params['type']
    assert_equal [user.id.to_s], Array(redirect_params.dig('parking_notice', 'member_ids'))
    assert_equal 'Repeat printed permit', redirect_params.dig('parking_notice', 'description')
    assert_equal expires_at, redirect_params.dig('parking_notice', 'expires_at')
    assert_equal 'Woodshop', redirect_params.dig('parking_notice', 'location')
    assert_equal 'South wall shelf', redirect_params.dig('parking_notice', 'location_detail')
    assert_equal "Parking permit created and printed to #{printer.name} (job default-printer-42).", flash[:notice]
    assert_equal 'default_printer', printed[:cups_printer_name]
    assert_equal '', printed[:cups_printer_server]
    assert_equal "parking_notice_#{notice.id}.pdf", printed[:filename]
    assert_equal({}, printed[:options])
    assert_predicate printed[:data], :present?
  end

  test 'create print another still saves when no default printer is configured' do
    user = users(:one)
    expires_at = '2026-06-01T17:00'

    assert_no_difference 'Printer.count' do
      assert_difference 'ParkingNotice.count', 1 do
        post parking_notices_url, params: {
          print_create_another_permit: 'Save, Print and Create Another Permit',
          parking_notice: {
            notice_type: 'permit',
            member_ids: [user.id],
            description: 'Repeat unprinted permit',
            expires_at: expires_at,
            location: 'Woodshop',
            location_detail: 'South wall shelf'
          }
        }
      end
    end

    location = URI.parse(response.location)
    redirect_params = Rack::Utils.parse_nested_query(location.query)

    assert_equal new_parking_notice_path, location.path
    assert_equal 'permit', redirect_params['type']
    assert_equal [user.id.to_s], Array(redirect_params.dig('parking_notice', 'member_ids'))
    assert_equal 'Repeat unprinted permit', redirect_params.dig('parking_notice', 'description')
    assert_equal expires_at, redirect_params.dig('parking_notice', 'expires_at')
    assert_equal 'Woodshop', redirect_params.dig('parking_notice', 'location')
    assert_equal 'South wall shelf', redirect_params.dig('parking_notice', 'location_detail')
    assert_equal 'Parking permit created successfully.', flash[:notice]
    assert_equal 'No default printer is configured.', flash[:alert]
  end

  test 'create print another still saves when printing fails' do
    user = users(:one)
    Printer.create!(name: 'Default Printer', cups_printer_name: 'default_printer', default_printer: true)
    expires_at = '2026-06-01T17:00'
    original_print_data = CupsService.method(:print_data)

    CupsService.define_singleton_method(:print_data) do |*_args, **_kwargs|
      raise CupsService::PrintError, 'printer is offline'
    end

    begin
      assert_difference 'ParkingNotice.count', 1 do
        post parking_notices_url, params: {
          print_create_another_permit: 'Save, Print and Create Another Permit',
          parking_notice: {
            notice_type: 'permit',
            member_ids: [user.id],
            description: 'Repeat failed print permit',
            expires_at: expires_at,
            location: 'Woodshop',
            location_detail: 'South wall shelf'
          }
        }
      end
    ensure
      CupsService.define_singleton_method(:print_data, original_print_data)
    end

    location = URI.parse(response.location)
    redirect_params = Rack::Utils.parse_nested_query(location.query)

    assert_equal new_parking_notice_path, location.path
    assert_equal 'permit', redirect_params['type']
    assert_equal [user.id.to_s], Array(redirect_params.dig('parking_notice', 'member_ids'))
    assert_equal 'Repeat failed print permit', redirect_params.dig('parking_notice', 'description')
    assert_equal expires_at, redirect_params.dig('parking_notice', 'expires_at')
    assert_equal 'Woodshop', redirect_params.dig('parking_notice', 'location')
    assert_equal 'South wall shelf', redirect_params.dig('parking_notice', 'location_detail')
    assert_equal 'Parking permit created successfully.', flash[:notice]
    assert_equal 'Print failed: printer is offline', flash[:alert]
  end

  test 'create saves a ticket without user' do
    assert_difference 'ParkingNotice.count', 1 do
      post parking_notices_url, params: {
        parking_notice: {
          notice_type: 'ticket',
          description: 'Anonymous ticket',
          location: 'Main Area',
          expires_at: 3.days.from_now
        }
      }
    end
    assert_redirected_to parking_notice_path(ParkingNotice.last)
  end

  test 'create rejects invalid permit (missing user)' do
    assert_no_difference 'ParkingNotice.count' do
      post parking_notices_url, params: {
        parking_notice: {
          notice_type: 'permit',
          description: 'No user',
          expires_at: 7.days.from_now
        }
      }
    end
    assert_response :unprocessable_content
  end

  # --- Edit / Update ---

  test 'edit renders form' do
    get edit_parking_notice_url(@active_permit)
    assert_response :success
  end

  test 'update modifies notice' do
    patch parking_notice_url(@active_permit), params: {
      parking_notice: { description: 'Updated description' }
    }
    assert_redirected_to parking_notice_path(@active_permit)
    assert_equal 'Updated description', @active_permit.reload.description
  end

  # --- PDF Download ---

  test 'download_pdf returns a PDF' do
    get download_pdf_parking_notice_url(@active_permit)
    assert_response :success
    assert_equal 'application/pdf', response.content_type
  end

  test 'create saves a ticket that requires admin clearance' do
    assert_difference 'ParkingNotice.count', 1 do
      post parking_notices_url, params: {
        parking_notice: {
          notice_type: 'ticket',
          description: 'Needs staff sign-off',
          location: 'Main Area',
          expires_at: 3.days.from_now,
          requires_admin_clearance: '1'
        }
      }
    end
    assert ParkingNotice.last.requires_admin_clearance?
  end

  # --- Clear ---

  test 'clear marks notice as cleared and returns to the notices list' do
    post clear_parking_notice_url(@active_permit)
    assert_redirected_to parking_notices_path
    assert @active_permit.reload.cleared?
  end

  test 'clear returns to the list passed as return_to' do
    return_to = user_path(@active_permit.members.first, tab: :parking)

    post clear_parking_notice_url(@active_permit, return_to: return_to)

    assert_redirected_to return_to
    assert @active_permit.reload.cleared?
  end

  test 'clear ignores an off-site return_to' do
    post clear_parking_notice_url(@active_permit, return_to: 'https://evil.example.com/phish')

    assert_redirected_to parking_notices_path
    assert @active_permit.reload.cleared?
  end

  test 'clear logs a cleared history event' do
    assert_difference -> { @active_permit.events.count }, 1 do
      post clear_parking_notice_url(@active_permit)
    end
    assert_equal 'cleared', @active_permit.events.recent_first.first.event_type
  end

  # --- Notes / history ---

  test 'add_note records a history note' do
    assert_difference -> { @active_permit.events.count }, 1 do
      post add_note_parking_notice_url(@active_permit), params: { note: 'Called the member' }
    end
    assert_redirected_to parking_notice_path(@active_permit)
    event = @active_permit.events.recent_first.first
    assert_equal 'note', event.event_type
    assert_equal 'Called the member', event.note
  end

  test 'add_note rejects a blank note' do
    assert_no_difference -> { @active_permit.events.count } do
      post add_note_parking_notice_url(@active_permit), params: { note: '  ' }
    end
    assert_redirected_to parking_notice_path(@active_permit)
  end

  private

  def sign_in_as_admin
    Rails.application.config.x.local_auth.enabled = true
    post local_login_path, params: {
      session: { email: 'admin@example.com', password: 'localpassword123' }
    }
    User.find_by('authentik_id LIKE ?', 'local:%')&.tap { |u| u.update!(is_admin: true) }
  end

  def count_slack_user_queries(&)
    queries = []
    callback = lambda do |*, payload|
      sql = payload[:sql].to_s
      queries << sql if sql.match?(/FROM "slack_users"/)
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)

    queries.size
  end

  def assert_expiration_quick_buttons
    assert_select '[data-controller="quick-expire"]'
    assert_select 'input[data-quick-expire-target="field"]'

    assert_select '.quick-expire', 7
    assert_select '.quick-expire[data-quick-expire-days-param="1"]', text: '1 day'
    assert_select '.quick-expire[data-quick-expire-days-param="3"]', text: '3 days'
    assert_select '.quick-expire[data-quick-expire-days-param="7"]', text: '1 week'
    assert_select '.quick-expire[data-quick-expire-days-param="14"]', text: '2 weeks'
    assert_select '.quick-expire[data-quick-expire-days-param="30"]', text: '30 days'
    assert_select '.quick-expire[data-quick-expire-days-param="180"]', text: '180 days'
    assert_select '.quick-expire[data-quick-expire-years-param="1"]', text: '1 year'

    # Every button must carry the action; a guard flag on the DOM used to leave
    # them inert after a Turbo cache restore.
    assert_select '.quick-expire[data-action="quick-expire#set"]', 7
  end
end
