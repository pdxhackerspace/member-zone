require 'test_helper'

class DeviceWebhooksControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    RateLimiting.reset!
    @device = WebhookDevice.create!(name: 'Front door kiosk')
    @member = users(:one)
  end

  test 'refuses a request without a token' do
    assert_no_difference %w[ParkingNotice.count ParkingPermitLink.count] do
      post device_parking_permit_webhook_path, params: { rfid: 'RFID001', mode: 'blank' }
    end

    assert_response :unauthorized
  end

  test 'refuses a disabled device' do
    @device.update!(enabled: false)

    post device_parking_permit_webhook_path, params: { rfid: 'RFID001', mode: 'blank' }, headers: auth_headers

    assert_response :unauthorized
  end

  test 'accepts the token as a header or a parameter' do
    post device_parking_permit_webhook_path, params: { rfid: 'RFID001', mode: 'link' },
                                             headers: { 'X-Device-Token' => @device.token }
    assert_response :created

    post device_parking_permit_webhook_path, params: { rfid: 'RFID001', mode: 'link', token: @device.token }
    assert_response :created
  end

  test 'records when and from where the device last called' do
    post device_parking_permit_webhook_path, params: { rfid: 'RFID001', mode: 'link' }, headers: auth_headers

    @device.reload
    assert_not_nil @device.last_used_at
    assert_not_nil @device.last_used_ip
  end

  test 'link mode emails a form link and creates no permit yet' do
    assert_no_difference 'ParkingNotice.count' do
      assert_enqueued_emails 1 do
        post device_parking_permit_webhook_path, params: { rfid: 'RFID001', mode: 'link' }, headers: auth_headers
      end
    end

    assert_response :created
    link = ParkingPermitLink.last
    assert_equal @member, link.user
    assert link.create_permit?
    assert_equal @device, link.webhook_device
    assert_in_delta 12.hours.from_now, link.expires_at, 5.seconds

    body = response.parsed_body
    assert_equal 'link', body['mode']
    assert_equal @member.display_name, body.dig('member', 'name')
    assert_not body.to_json.include?('/parking_permit/'), 'the form link must only go to the member'
  end

  test 'blank mode issues a two-week permit awaiting details' do
    assert_difference 'ParkingNotice.count', 1 do
      assert_enqueued_emails 1 do
        post device_parking_permit_webhook_path, params: { rfid: 'RFID001', mode: 'blank' }, headers: auth_headers
      end
    end

    assert_response :created
    notice = ParkingNotice.order(:id).last
    assert notice.permit?
    assert notice.active?
    assert notice.awaiting_details?
    assert_equal [@member], notice.members.to_a
    assert_equal @device, notice.webhook_device
    assert_in_delta 2.weeks.from_now, notice.expires_at, 5.seconds
    assert ParkingPermitLink.exists?(parking_notice: notice, purpose: 'complete_permit')
    assert_equal notice.id, response.parsed_body.dig('permit', 'id')
  end

  test 'finds the member by username or email' do
    post device_parking_permit_webhook_path, params: { username: @member.username, mode: 'link' },
                                             headers: auth_headers
    assert_response :created
    assert_equal @member, ParkingPermitLink.last.user

    post device_parking_permit_webhook_path, params: { email: @member.email, mode: 'link' }, headers: auth_headers
    assert_response :created
    assert_equal @member, ParkingPermitLink.last.user
  end

  test 'an unknown member is not found' do
    post device_parking_permit_webhook_path, params: { rfid: 'NOPE', mode: 'blank' }, headers: auth_headers

    assert_response :not_found
  end

  test 'a request without a member or with an unknown mode is a bad request' do
    post device_parking_permit_webhook_path, params: { mode: 'blank' }, headers: auth_headers
    assert_response :bad_request

    post device_parking_permit_webhook_path, params: { rfid: 'RFID001', mode: 'sticker' }, headers: auth_headers
    assert_response :bad_request
  end

  test 'a banned member is refused' do
    @member.ban!

    post device_parking_permit_webhook_path, params: { rfid: 'RFID001', mode: 'blank' }, headers: auth_headers

    assert_response :unprocessable_content
  end

  private

  def auth_headers
    { 'Authorization' => "Bearer #{@device.token}" }
  end
end
