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
      #
      # A blank permit can also be printed in the same request: `print: true` sends it to the
      # default printer, `printer_id` to a particular one. The printer is checked before anything
      # is issued, but a printer that then refuses the job does not undo the permit — the response
      # says what happened so the device can tell the member.
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
          printer = requested_printer
          return if performed?

          result = ParkingPermits::DeviceIssuer.call(
            api_token: current_api_token,
            mode: params[:mode],
            member_params: { rfid: params[:rfid], username: params[:username], email: params[:email] }
          )
          return render_refusal(result) unless result.success?

          Rails.logger.info("[API] #{current_api_token.name} parking permit (#{result.mode}) " \
                            "for user #{result.user.id}")
          render json: { data: permit_request_json(result).merge(print: print_permit(result, printer)) },
                 status: :created
        end

        private

        # The printer asked for, the default printer for `print: true`, or nil when printing was not
        # asked for. Renders an error (and returns nil) when the request cannot be printed.
        def requested_printer
          return nil unless print_requested?
          return render_error(:bad_request, 'Only blank permits can be printed.', status: :bad_request) unless
            params[:mode].to_s.strip.downcase == 'blank'

          printer = params[:printer_id].present? ? Printer.find(params[:printer_id]) : Printer.default
          printer || render_error(:conflict, 'No printer is configured.', status: :conflict)
        end

        def print_requested?
          params[:printer_id].present? || ActiveModel::Type::Boolean.new.cast(params[:print])
        end

        def print_permit(result, printer)
          return nil if printer.nil?

          printed = ParkingNotices::Print.call(notice: result.parking_notice, printer: printer, layout: params[:layout])
          { printer_id: printer.id, printer_name: printer.name, job_id: printed.job_id&.to_s,
            error: (printed.message.presence || 'The printer did not accept the job.' unless printed.success?) }
        end

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
