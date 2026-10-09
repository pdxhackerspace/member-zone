# Webhooks called by hardware Member Zone knows about — access control kiosks and the like — each
# authenticating with the token issued to it under Settings → Webhook Devices.
#
#   POST /webhooks/devices/parking_permits
#   Authorization: Bearer <device token>     (or X-Device-Token header, or a token param)
#   rfid=<fob> | username=<username> | email=<full email>
#   mode=link | blank
class DeviceWebhooksController < ApplicationController
  # Machine-to-machine requests carry a device token instead of a Rails session.
  # codeql[rb/csrf-protection-disabled]: M2M endpoint authenticated by per-device bearer token.
  skip_before_action :verify_authenticity_token

  rate_limit to: 60, within: 1.minute, name: 'device-webhook', store: RateLimiting.store,
             with: -> { render json: { error: 'rate limited' }, status: :too_many_requests }

  before_action :authenticate_device!

  def parking_permit
    result = ParkingPermits::DeviceIssuer.call(
      device: @device,
      mode: params[:mode],
      member_params: { rfid: params[:rfid], username: params[:username], email: params[:email] }
    )

    unless result.success?
      Rails.logger.info("[DeviceWebhook] #{@device.name} parking permit refused: #{result.error}")
      render json: { error: result.error }, status: result.status
      return
    end

    Rails.logger.info("[DeviceWebhook] #{@device.name} parking permit (#{result.mode}) for user #{result.user.id}")
    render json: parking_permit_response(result), status: :created
  end

  private

  def authenticate_device!
    @device = WebhookDevice.authenticate(provided_token)
    if @device
      @device.record_use!(ip: request.remote_ip)
      return
    end

    Rails.logger.warn("[DeviceWebhook] rejected request with an unknown or disabled token from #{request.remote_ip}")
    render json: { error: 'invalid token' }, status: :unauthorized
  end

  def provided_token
    bearer = request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]
    bearer.presence || request.headers['X-Device-Token'].presence || params[:token].presence
  end

  # Enough for a kiosk to tell the member what happened, and to print a blank permit with their
  # name and the expiry on it. Never includes the form link: that only goes to the member's inbox.
  def parking_permit_response(result)
    body = { status: 'created', mode: result.mode, member: { name: result.user.display_name } }
    body[:link_expires_at] = result.link.expires_at.iso8601 if result.mode == 'link'
    body[:email_sent] = result.link.present?
    if result.parking_notice
      body[:permit] = { id: result.parking_notice.id, expires_at: result.parking_notice.expires_at.iso8601 }
    end
    body
  end
end
