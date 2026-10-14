module Api
  module V1
    # What the staff and self-service parking endpoints share: listing, showing, notes, the PDF,
    # and printing. Including controllers say which notices they reach (+notice_scope+) and where
    # photos are downloaded from (+photo_download_path+).
    #
    # The rules themselves live in the ParkingNotices services, shared with the website; this
    # only turns their results into responses.
    module ParkingNoticeEndpoints
      extend ActiveSupport::Concern

      included do
        # Every action but the collection ones works on one notice.
        before_action :set_notice, unless: -> { action_name.in?(%w[index create]) }
      end

      # How each refusal a parking service can return is reported: status, error code, message.
      ERRORS = {
        already_cleared: [:conflict, :conflict, 'This notice has already been cleared.'],
        clearance_required: [:forbidden, :forbidden, 'This notice needs staff clearance.'],
        not_needed: [:conflict, :conflict, 'This notice does not need a clearance request.'],
        already_requested: [:conflict, :conflict, 'Clearance has already been requested.'],
        not_printable: [:conflict, :conflict, 'Expired or cleared notices cannot be printed.'],
        print_failed: [:bad_gateway, :print_failed, 'The printer did not accept the job.']
      }.freeze

      def index
        # preload, not includes: the member filters join parking_notice_members, and eager loading
        # members through that join would list only the member filtered on.
        notices = filtered(notice_scope).preload(:issued_by, :cleared_by, :members, photos_attachments: :blob)
        records, meta = paginate(notices.newest_first)
        render json: { data: records.map { |notice| serialize(notice) }, meta: meta }
      end

      def show
        render json: { data: serialize(@notice, events: true) }
      end

      def notes
        render_result(ParkingNotices::AddNote.call(notice: @notice, actor: current_user, note: params[:note]))
      end

      def pdf
        send_data ParkingNoticePdf.new(@notice).render,
                  filename: "parking_#{@notice.notice_type}_#{@notice.id}.pdf", type: 'application/pdf',
                  disposition: 'attachment'
      end

      def print
        printer = Printer.find(params.require(:printer_id))
        result = ParkingNotices::Print.call(notice: @notice, printer: printer, layout: params[:layout])
        return respond_with_error(result) unless result.success?

        render json: { data: { printer_id: printer.id, job_id: result.job_id.to_s } }
      end

      private

      def set_notice
        @notice = notice_scope.find(params[:notice_id] || params[:id])
      end

      def filtered(notices)
        notices = notices.where(notice_type: enum_param(:type, ParkingNotice::NOTICE_TYPES)) if params[:type]
        notices = notices.where(status: enum_param(:status, ParkingNotice::STATUSES)) if params[:status]
        notices
      end

      def enum_param(name, allowed)
        value = params[name].to_s
        return value if allowed.include?(value)

        raise ActionController::BadRequest, "#{name} must be one of: #{allowed.join(', ')}"
      end

      def serialize(notice, events: false)
        ParkingNoticeSerializer.call(notice, photo_path: method(:photo_download_path), events: events)
      end

      def notice_attributes(*keys)
        params.permit(*keys).to_h.symbolize_keys
      end

      # nil when the request left member_ids out or sent null, so an update leaves the members
      # alone; an empty list clears them.
      def requested_member_ids
        Array(params[:member_ids]) unless params[:member_ids].nil?
      end

      def render_result(result, status: :ok)
        return respond_with_error(result) unless result.success?

        render json: { data: serialize(result.notice.reload, events: true) }, status: status
      end

      def respond_with_error(result)
        case result.error
        when :invalid then render_validation_errors(result.notice)
        when :blank_note then render_field_error(:note, "can't be blank", 'Note cannot be blank.')
        when :invalid_photo then render_field_error(:photos, result.message, result.message)
        else
          status, code, message = ERRORS.fetch(result.error)
          render_error(code, [message, result.message].compact.join(' '), status: status)
        end
      end

      def render_field_error(field, problem, message)
        render_error(:validation_failed, message, status: :unprocessable_content,
                                                  details: { fields: { field => [problem] } })
      end
    end
  end
end
