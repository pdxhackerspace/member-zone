class ParkingNoticesController < AuthenticatedController
  include Pagy::Method
  include ParkingNoticePrinting

  before_action -> { require_privilege!(:'parking.manage_notices') }

  before_action :set_parking_notice,
                only: %i[show edit update clear add_note download_pdf print_notice remove_photo download_photo]
  before_action :require_clearance_authority!, only: :clear

  def index
    @parking_notices = ParkingNotice.includes(:issued_by, user: :slack_user).newest_first

    @parking_notices = @parking_notices.where(notice_type: params[:type]) if params[:type].present?
    @parking_notices = @parking_notices.where(status: params[:status]) if params[:status].present?

    @status_counts = {
      all: ParkingNotice.count,
      active: ParkingNotice.active_notices.count,
      expired: ParkingNotice.expired_notices.count,
      cleared: ParkingNotice.cleared_notices.count
    }

    @pagy, @parking_notices = pagy(@parking_notices, limit: 25)
    @printers = Printer.ordered
  end

  def show
    @printers = Printer.ordered
  end

  def new
    @parking_notice = ParkingNotice.new(
      notice_type: params[:type].presence || 'permit',
      expires_at: 7.days.from_now
    )
    @parking_notice.assign_attributes(parking_notice_prefill_params) if params[:parking_notice].present?
    load_form_data
  end

  def edit
    load_form_data
  end

  def create
    @parking_notice = ParkingNotice.new(parking_notice_params)
    @parking_notice.issued_by = current_user
    @parking_notice.event_actor = current_user

    if @parking_notice.save
      journal_action = @parking_notice.permit? ? 'parking_permit_issued' : 'parking_ticket_issued'

      @parking_notice.record_journal_entry!(journal_action, actor: current_user)
      @parking_notice.enqueue_notification!(@parking_notice.issued_template_key)

      if print_and_create_another_permit?
        redirect_after_print_and_create_another_permit
        return
      end

      if create_another_permit?
        redirect_to new_parking_notice_path(type: 'permit', parking_notice: parking_notice_prefill_params),
                    notice: 'Parking permit created successfully.'
        return
      end

      redirect_to parking_notice_path(@parking_notice),
                  notice: "Parking #{@parking_notice.notice_type} created successfully."
    else
      load_form_data
      render :new, status: :unprocessable_content
    end
  end

  def update
    @parking_notice.event_actor = current_user
    if @parking_notice.update(parking_notice_params)
      redirect_to parking_notice_path(@parking_notice),
                  notice: "Parking #{@parking_notice.notice_type} updated successfully."
    else
      load_form_data
      render :edit, status: :unprocessable_content
    end
  end

  def clear
    @parking_notice.event_actor = current_user
    @parking_notice.clear!(current_user)
    @parking_notice.record_journal_entry!('parking_notice_cleared', actor: current_user)

    # Return to the list the admin was viewing rather than the cleared notice.
    redirect_to url_from(params[:return_to]) || parking_notices_path,
                notice: "Parking #{@parking_notice.notice_type} marked as cleared."
  end

  def add_note
    note = params[:note].to_s.strip

    if note.blank?
      redirect_to parking_notice_path(@parking_notice), alert: 'Note cannot be blank.'
      return
    end

    @parking_notice.log_event!('note', actor: current_user, note: note)
    redirect_to parking_notice_path(@parking_notice), notice: 'Note added.'
  end

  def download_pdf
    pdf = ParkingNoticePdf.new(@parking_notice)
    type_label = @parking_notice.permit? ? 'permit' : 'ticket'
    filename = "parking_#{type_label}_#{@parking_notice.id}_#{@parking_notice.created_at.strftime('%Y%m%d')}.pdf"

    send_data pdf.render,
              filename: filename,
              type: 'application/pdf',
              disposition: 'attachment'
  end

  def print_notice
    unless @parking_notice.active?
      redirect_to parking_notice_path(@parking_notice),
                  alert: 'Expired or cleared notices cannot be printed.'
      return
    end

    printer = Printer.find(params[:printer_id])
    job_id = print_parking_notice_to_printer(@parking_notice, printer)

    redirect_to parking_notice_path(@parking_notice),
                notice: "Printed to #{printer.name} (job #{job_id})."
  rescue CupsService::PrintError => e
    redirect_to parking_notice_path(@parking_notice),
                alert: "Print failed: #{e.message}"
  end

  def remove_photo
    photo = @parking_notice.photos.find(params[:photo_id])
    photo.purge
    redirect_to parking_notice_path(@parking_notice), notice: 'Photo removed.'
  end

  def download_photo
    photo = @parking_notice.photos.find(params[:photo_id])
    disposition = params[:disposition] == 'inline' ? 'inline' : 'attachment'

    send_data photo.download,
              filename: photo.filename.to_s,
              type: photo.content_type,
              disposition: disposition
  end

  private

  # A notice flagged as needing staff clearance is the one case where reaching this page is
  # not enough — that flag exists precisely to hold a notice open until someone with the
  # authority to clear it looks at it. ParkingNotice#clearable_by? is the single answer,
  # shared with the member-facing permit page.
  def require_clearance_authority!
    return if @parking_notice.clearable_by?(current_user)

    redirect_to parking_notice_path(@parking_notice),
                alert: 'That notice needs staff clearance.'
  end

  def set_parking_notice
    @parking_notice = ParkingNotice.includes(user: :slack_user).find(params[:id])
  end

  def load_form_data
    @rooms = Room.ordered
    @users = User.ordered_by_display_name.includes(:slack_user)
  end

  def parking_notice_params
    params.expect(
      parking_notice: [:notice_type, :user_id, :description, :location,
                       :location_detail, :expires_at, :notes, :requires_admin_clearance,
                       { photos: [] }]
    )
  end

  def parking_notice_prefill_params
    params.expect(
      parking_notice: %i[user_id description expires_at location location_detail]
    )
  end

  def create_another_permit?
    @parking_notice.permit? && params[:create_another_permit].present?
  end

  def print_and_create_another_permit?
    @parking_notice.permit? && params[:print_create_another_permit].present?
  end

  def redirect_after_print_and_create_another_permit
    printer = Printer.default
    redirect_path = new_parking_notice_path(type: 'permit', parking_notice: parking_notice_prefill_params)

    if printer.blank?
      redirect_to redirect_path,
                  notice: 'Parking permit created successfully.',
                  alert: 'No default printer is configured.'
      return
    end

    job_id = print_parking_notice_to_printer(@parking_notice, printer)

    redirect_to redirect_path,
                notice: "Parking permit created and printed to #{printer.name} (job #{job_id})."
  rescue CupsService::PrintError => e
    redirect_to redirect_path,
                notice: 'Parking permit created successfully.',
                alert: "Print failed: #{e.message}"
  end
end
