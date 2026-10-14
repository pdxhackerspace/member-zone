module Api
  module V1
    module Parking
      # A parking permit for whoever just badged in at an access control device. The device holds
      # a service-account token with parking.issue_for_members, which lets it act for a member it
      # identifies by key fob, username, or full email address — and nothing more.
      #
      # Mode `link` emails the member a 12-hour, no-login form; mode `blank` issues a two-week
      # permit to hand-write and emails a link to fill in its details. See
      # ParkingPermits::DeviceIssuer.
      class PermitRequestsController < BaseController
        # How each refusal from ParkingPermits::DeviceIssuer is reported.
        ERROR_CODES = {
          bad_request: :bad_request,
          not_found: :not_found,
          conflict: :conflict,
          unprocessable_content: :ineligible_member
        }.freeze

        before_action -> { require_scope!(:'parking.issue_for_members') }

        def create
          result = ParkingPermits::DeviceIssuer.call(
            api_token: current_api_token,
            mode: params[:mode],
            member_params: { rfid: params[:rfid], username: params[:username], email: params[:email] }
          )
          return render_refusal(result) unless result.success?

          Rails.logger.info("[API] #{current_api_token.name} parking permit (#{result.mode}) " \
                            "for user #{result.user.id}")
          render json: { data: permit_request_json(result) }, status: :created
        end

        private

        def render_refusal(result)
          Rails.logger.info("[API] #{current_api_token.name} parking permit refused: #{result.error}")
          render_error(ERROR_CODES.fetch(result.status), "#{result.error.upcase_first}.", status: result.status)
        end

        # Enough for a kiosk to tell the member what happened, and to print a blank permit with their
        # name and the expiry on it. Never includes the form link: that only goes to the member's inbox.
        def permit_request_json(result)
          {
            mode: result.mode,
            member: { name: result.user.display_name },
            email_sent: result.link.present?,
            link_expires_at: (result.link.expires_at.iso8601 if result.mode == 'link'),
            permit: result.parking_notice && { id: result.parking_notice.id,
                                               expires_at: result.parking_notice.expires_at.iso8601 }
          }
        end
      end
    end
  end
end
