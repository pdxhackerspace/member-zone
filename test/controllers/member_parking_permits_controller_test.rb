require 'test_helper'

class MemberParkingPermitsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'member can open new permit form' do
    sign_in_as_member

    get new_member_parking_permit_path
    assert_response :success
    assert_match(/New Parking Permit/i, response.body)
    assert_expiration_quick_buttons
  end

  test 'member can create own parking permit' do
    sign_in_as_member
    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")

    assert_difference 'ParkingNotice.count', 1 do
      post member_parking_permits_path, params: {
        parking_notice: {
          description: 'My project',
          location: 'Woodshop',
          location_detail: 'Bench A',
          expires_at: 3.days.from_now.strftime('%Y-%m-%dT%H:%M')
        }
      }
    end

    notice = ParkingNotice.order(:created_at).last
    assert_equal 'permit', notice.notice_type
    assert_equal 'active', notice.status
    assert notice.member?(member)
    assert_equal member.id, notice.issued_by_id
    assert_redirected_to user_path(member, tab: :parking)
  end

  test 'member can create permit expiring in exactly 2 weeks' do
    sign_in_as_member

    assert_difference 'ParkingNotice.count', 1 do
      post member_parking_permits_path, params: {
        parking_notice: {
          description: 'Two week project',
          location: 'Woodshop',
          expires_at: 2.weeks.from_now.strftime('%Y-%m-%dT%H:%M')
        }
      }
    end

    assert_redirected_to user_path(current_member, tab: :parking)
  end

  test 'member cannot create permit longer than 2 weeks' do
    sign_in_as_member

    assert_no_difference 'ParkingNotice.count' do
      post member_parking_permits_path, params: {
        parking_notice: {
          description: 'Long project',
          location: 'Woodshop',
          expires_at: 3.weeks.from_now.strftime('%Y-%m-%dT%H:%M')
        }
      }
    end

    assert_response :unprocessable_content
    assert_match(/must be within 2 weeks/i, response.body)
  end

  test 'member cannot create permit with two week quick pick time past the max window' do
    sign_in_as_member
    travel_to Time.zone.local(2026, 10, 5, 8, 0, 0) do
      # Calendar day + 5pm would land after the true two-week limit from now.
      too_late = 14.days.from_now.change(hour: 17, min: 0)

      assert_no_difference 'ParkingNotice.count' do
        post member_parking_permits_path, params: {
          parking_notice: {
            description: 'Late afternoon pick',
            location: 'Woodshop',
            expires_at: too_late.strftime('%Y-%m-%dT%H:%M')
          }
        }
      end

      assert_response :unprocessable_content
      assert_match(/must be within 2 weeks/i, response.body)
    end
  end

  test 'member cannot extend permit beyond 2 weeks from creation' do
    sign_in_as_member
    travel_to Time.zone.local(2026, 10, 1, 10, 0, 0) do
      permit = member_permit
      travel 8.days

      assert_no_changes -> { permit.reload.expires_at } do
        patch member_parking_permit_path(permit), params: {
          parking_notice: {
            description: permit.description,
            location: permit.location,
            expires_at: 15.days.after(permit.created_at).strftime('%Y-%m-%dT%H:%M')
          }
        }
      end

      assert_response :unprocessable_content
      assert_match(/must be within 2 weeks/i, response.body)
    end
  end

  test 'member can update permit when expiration exceeds self-service cap if unchanged' do
    sign_in_as_member
    permit = travel_to(Time.zone.local(2026, 1, 1, 10, 0, 0)) { member_permit_for(current_member) }

    permit.update_columns(created_at: 20.days.ago, expires_at: 10.days.from_now)
    expires_param = permit.expires_at.strftime('%Y-%m-%dT%H:%M')

    patch member_parking_permit_path(permit), params: {
      parking_notice: {
        description: 'Updated description',
        location: permit.location,
        expires_at: expires_param
      }
    }

    assert_redirected_to user_path(current_member, tab: :parking)
    assert_equal 'Updated description', permit.reload.description
  end

  test 'anonymous user cannot access member permit form' do
    get new_member_parking_permit_path
    assert_redirected_to login_path
  end

  test 'member can close own active permit' do
    sign_in_as_member
    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")
    permit = member_permit_for(member)

    patch close_member_parking_permit_path(permit)

    assert_redirected_to user_path(member, tab: :parking)
    permit.reload
    assert_equal 'cleared', permit.status
    assert_equal member.id, permit.cleared_by_id
  end

  test 'closing a notice returns to the list passed as return_to' do
    sign_in_as_member
    permit = member_permit
    return_to = root_path(tab: :parking, statuses: 'active,expired')

    patch close_member_parking_permit_path(permit, return_to: return_to)

    assert_redirected_to return_to
    assert_equal 'cleared', permit.reload.status
  end

  test 'closing a notice ignores an off-site return_to' do
    sign_in_as_member
    permit = member_permit

    patch close_member_parking_permit_path(permit, return_to: 'https://evil.example.com/phish')

    assert_redirected_to user_path(current_member, tab: :parking)
    assert_equal 'cleared', permit.reload.status
  end

  test 'member can close their own ticket when admin clearance is not required' do
    sign_in_as_member
    ticket = member_ticket

    patch close_member_parking_permit_path(ticket)

    assert_redirected_to user_path(current_member, tab: :parking)
    assert_equal 'cleared', ticket.reload.status
    assert_equal current_member.id, ticket.cleared_by_id
  end

  test 'member can clear their own expired ticket' do
    sign_in_as_member
    ticket = member_ticket
    ticket.update!(status: 'expired', expires_at: 2.days.ago)

    patch close_member_parking_permit_path(ticket)

    assert_redirected_to user_path(current_member, tab: :parking)
    assert_equal 'cleared', ticket.reload.status
    assert_equal current_member.id, ticket.cleared_by_id
  end

  test 'member cannot clear an expired ticket that requires admin clearance' do
    sign_in_as_member
    ticket = member_ticket
    ticket.update!(status: 'expired', expires_at: 2.days.ago, requires_admin_clearance: true)

    patch close_member_parking_permit_path(ticket)

    assert_redirected_to user_path(current_member, tab: :parking)
    assert_equal 'expired', ticket.reload.status
  end

  test 'member can request clearance for an expired ticket that requires admin clearance' do
    sign_in_as_member
    ticket = member_ticket
    ticket.update!(status: 'expired', expires_at: 2.days.ago, requires_admin_clearance: true)

    post request_clearance_member_parking_permit_path(ticket)

    assert_redirected_to user_path(current_member, tab: :parking)
    assert ticket.reload.clearance_requested?
  end

  test 'member cannot close a ticket that requires admin clearance' do
    sign_in_as_member
    ticket = member_ticket
    ticket.update!(requires_admin_clearance: true)

    patch close_member_parking_permit_path(ticket)

    assert_redirected_to user_path(current_member, tab: :parking)
    assert_equal 'active', ticket.reload.status
  end

  test 'member can request clearance for a ticket that requires admin clearance' do
    sign_in_as_member
    ticket = member_ticket
    ticket.update!(requires_admin_clearance: true)

    assert_difference -> { ticket.events.count }, 1 do
      post request_clearance_member_parking_permit_path(ticket)
    end

    assert_redirected_to user_path(current_member, tab: :parking)
    assert ticket.reload.clearance_requested?
    assert_equal current_member.id, ticket.clearance_requested_by_id
  end

  test 'member cannot request clearance when it is not required' do
    sign_in_as_member
    ticket = member_ticket

    post request_clearance_member_parking_permit_path(ticket)

    assert_redirected_to user_path(current_member, tab: :parking)
    assert_not ticket.reload.clearance_requested?
  end

  test 'member can add a note to the history of their own notice' do
    sign_in_as_member
    permit = member_permit

    assert_difference -> { permit.events.count }, 1 do
      post add_note_member_parking_permit_path(permit), params: { note: 'Picked up tomorrow' }
    end

    assert_redirected_to member_parking_permit_path(permit)
    event = permit.events.last
    assert_equal 'note', event.event_type
    assert_equal 'Picked up tomorrow', event.note
  end

  test 'member cannot add a blank note' do
    sign_in_as_member
    permit = member_permit

    assert_no_difference -> { permit.events.count } do
      post add_note_member_parking_permit_path(permit), params: { note: '   ' }
    end

    assert_redirected_to member_parking_permit_path(permit)
  end

  test "member cannot close another member's permit" do
    sign_in_as_member
    other_permit = parking_notices(:active_permit)

    patch close_member_parking_permit_path(other_permit)

    assert_equal 'active', other_permit.reload.status
  end

  test 'anonymous user cannot close a permit' do
    permit = parking_notices(:active_permit)

    patch close_member_parking_permit_path(permit)

    assert_redirected_to login_path
    assert_equal 'active', permit.reload.status
  end

  test 'member cannot close an already-cleared permit' do
    sign_in_as_member
    permit = member_permit(status: 'cleared')

    patch close_member_parking_permit_path(permit)

    assert_redirected_to user_path(current_member, tab: :parking)
    assert_equal 'cleared', permit.reload.status
  end

  test 'member can view own permit with edit and clear actions' do
    sign_in_as_member
    permit = member_permit

    get member_parking_permit_path(permit)

    assert_response :success
    assert_select 'a[href=?]', edit_member_parking_permit_path(permit)
    assert_select 'form[action=?]', close_member_parking_permit_path(permit)
  end

  test 'member can print own permit when a printer is configured' do
    sign_in_as_member
    permit = member_permit
    printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')
    original_print_data = CupsService.method(:print_data)

    CupsService.define_singleton_method(:print_data) do |*_args, **_kwargs|
      'member-print-99'
    end

    begin
      post print_notice_member_parking_permit_path(permit, printer_id: printer.id)
    ensure
      CupsService.define_singleton_method(:print_data, original_print_data)
    end

    assert_redirected_to member_parking_permit_path(permit)
    assert_equal "Printed to #{printer.name} (job member-print-99).", flash[:notice]
  end

  test 'member cannot print an expired permit' do
    sign_in_as_member
    permit = member_permit(status: 'expired')
    printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')

    post print_notice_member_parking_permit_path(permit, printer_id: printer.id)

    assert_redirected_to member_parking_permit_path(permit)
    assert_match(/cannot be printed/i, flash[:alert])
  end

  test 'member permit show hides print action for an expired permit' do
    sign_in_as_member
    permit = member_permit(status: 'expired')
    printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')

    get member_parking_permit_path(permit)

    assert_response :success
    assert_select 'a[href=?]', print_notice_member_parking_permit_path(permit, printer_id: printer.id), false
    assert_select 'form[action=?]', close_member_parking_permit_path(permit)
  end

  test 'member permit show includes print action when printers are configured' do
    sign_in_as_member
    permit = member_permit
    printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')

    get member_parking_permit_path(permit)

    assert_response :success
    assert_select 'a[href=?]', print_notice_member_parking_permit_path(permit, printer_id: printer.id)
  end

  test 'member cannot print their own ticket' do
    sign_in_as_member
    ticket = member_ticket
    printer = Printer.create!(name: 'Front Desk', cups_printer_name: 'front_desk')

    post print_notice_member_parking_permit_path(ticket, printer_id: printer.id)

    assert_redirected_to user_path(current_member, tab: :parking)
  end

  test 'member can view own ticket with a clear action but no edit action' do
    sign_in_as_member
    ticket = member_ticket

    get member_parking_permit_path(ticket)

    assert_response :success
    assert_select 'a[href=?]', edit_member_parking_permit_path(ticket), false
    assert_select 'form[action=?]', close_member_parking_permit_path(ticket)
  end

  test 'member sees a request-clearance action for a ticket needing admin clearance' do
    sign_in_as_member
    ticket = member_ticket
    ticket.update!(requires_admin_clearance: true)

    get member_parking_permit_path(ticket)

    assert_response :success
    assert_select 'form[action=?]', request_clearance_member_parking_permit_path(ticket)
    assert_select 'form[action=?]', close_member_parking_permit_path(ticket), false
  end

  test 'member can open edit form for own permit' do
    sign_in_as_member
    permit = member_permit

    get edit_member_parking_permit_path(permit)

    assert_response :success
    assert_match(/Edit Parking Permit/i, response.body)
  end

  test 'member cannot edit their own ticket' do
    sign_in_as_member
    ticket = member_ticket

    get edit_member_parking_permit_path(ticket)

    assert_redirected_to user_path(current_member, tab: :parking)
  end

  test 'member can update own permit' do
    sign_in_as_member
    permit = member_permit

    patch member_parking_permit_path(permit), params: {
      parking_notice: { description: 'Updated description', location: 'Metal Shop' }
    }

    assert_redirected_to user_path(current_member, tab: :parking)
    permit.reload
    assert_equal 'Updated description', permit.description
    assert_equal 'Metal Shop', permit.location
  end

  test 'member cannot update their own ticket' do
    sign_in_as_member
    ticket = member_ticket

    patch member_parking_permit_path(ticket), params: {
      parking_notice: { description: 'Tampered' }
    }

    assert_redirected_to user_path(current_member, tab: :parking)
    assert_not_equal 'Tampered', ticket.reload.description
  end

  test "member cannot view another member's notice" do
    sign_in_as_member
    other = parking_notices(:active_permit)

    get member_parking_permit_path(other)

    assert_redirected_to user_path(current_member, tab: :parking)
  end

  test "member cannot update another member's permit" do
    sign_in_as_member
    other = parking_notices(:active_permit)
    original = other.description

    patch member_parking_permit_path(other), params: {
      parking_notice: { description: 'Hijacked' }
    }

    assert_redirected_to user_path(current_member, tab: :parking)
    assert_equal original, other.reload.description
  end

  test 'anonymous user cannot view a permit' do
    permit = parking_notices(:active_permit)

    get member_parking_permit_path(permit)

    assert_redirected_to login_path
  end

  test 'member_search hides private profiles' do
    sign_in_as_member
    private_member = users(:two)
    private_member.update!(profile_visibility: 'private')

    get member_search_member_parking_permits_path, params: { q: private_member.username[0, 2] },
                                                   headers: { 'Accept' => 'application/json' }

    assert_response :success
    ids = response.parsed_body.pluck('id')
    assert_not_includes ids, private_member.id
  end

  test 'member cannot add a private-profile member to their permit' do
    sign_in_as_member
    private_member = users(:two)
    private_member.update!(profile_visibility: 'private')

    post member_parking_permits_path, params: {
      parking_notice: {
        description: 'Solo project',
        location: 'Woodshop',
        expires_at: 3.days.from_now.strftime('%Y-%m-%dT%H:%M'),
        member_ids: [private_member.id]
      }
    }

    notice = ParkingNotice.order(:created_at).last
    assert notice.member?(current_member)
    assert_not notice.member?(private_member)
  end

  private

  def current_member
    User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")
  end

  def member_permit(status: 'active')
    member_permit_for(current_member, status: status)
  end

  def member_permit_for(member, status: 'active')
    notice = ParkingNotice.new(
      notice_type: 'permit', status: status, issued_by: member,
      expires_at: 3.days.from_now, description: 'My item', location: 'Woodshop'
    )
    notice.build_members_from_ids!([member.id])
    notice.save!
    notice
  end

  def member_ticket
    notice = ParkingNotice.create!(
      notice_type: 'ticket', status: 'active', issued_by: users(:one),
      expires_at: 3.days.from_now, description: 'Enforcement', location: 'Main Area'
    )
    notice.replace_members!([current_member.id])
    notice
  end

  def sign_in_as_member
    post local_login_path, params: {
      session: { email: local_accounts(:regular_member).email, password: 'memberpassword123' }
    }
  end

  def assert_expiration_quick_buttons
    assert_select '[data-controller="quick-expire"]'
    assert_select 'input[name="parking_notice[expires_at]"][data-quick-expire-target="field"]'

    assert_select '.quick-expire', 4
    assert_select '.quick-expire[data-quick-expire-days-param="1"]', text: '1 day'
    assert_select '.quick-expire[data-quick-expire-days-param="3"]', text: '3 days'
    assert_select '.quick-expire[data-quick-expire-days-param="7"]', text: '1 week'
    assert_select '.quick-expire[data-quick-expire-days-param="14"]', text: '2 weeks'

    # Every button must carry the action; a guard flag on the DOM used to leave
    # them inert after a Turbo cache restore.
    assert_select '.quick-expire[data-action="quick-expire#set"]', 4

    assert_select 'input[name="parking_notice[expires_at]"][max]'
  end
end
