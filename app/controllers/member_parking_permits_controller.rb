class MemberParkingPermitsController < AuthenticatedController
  include ParkingNoticePrinting

  before_action :set_owned_notice, only: %i[show edit update close request_clearance add_note print_notice]
  before_action :require_owned_permit, only: %i[edit update print_notice]

  # Members may view their own permits and tickets.
  def show
    @printers = Printer.ordered
  end

  def new
    @parking_notice = ParkingNotice.new(
      notice_type: 'permit',
      expires_at: 7.days.from_now
    )
  end

  # Members may edit only their own permits (guarded by require_owned_permit).
  def edit; end

  def create
    result = ParkingNotices::Issue.call(
      actor: current_user, attributes: member_parking_permit_params, member_ids: member_ids_param, self_service: true
    )
    @parking_notice = result.notice

    if result.success?
      redirect_to user_path(current_user, tab: :parking), notice: 'Parking permit created successfully.'
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    result = ParkingNotices::Update.call(
      notice: @parking_notice, actor: current_user, attributes: member_parking_permit_params,
      member_ids: submitted_member_ids, self_service: true
    )

    if result.success?
      redirect_to user_path(current_user, tab: :parking), notice: 'Parking permit updated.'
    else
      render :edit, status: :unprocessable_content
    end
  end

  def member_search
    query = params[:q].to_s.strip
    users = if query.length >= 1
              ParkingNotices::MemberResolution
                .pickable_for(current_user)
                .where('username ILIKE ?', "#{User.sanitize_sql_like(query)}%")
                .order(:username)
                .limit(10)
            else
              User.none
            end

    render json: users.pluck(:id, :username).map { |id, username| { id: id, username: username } }
  end

  # Members may clear their own active or expired notices unless admin
  # clearance is required.
  def close
    result = ParkingNotices::Clear.call(notice: @parking_notice, actor: current_user)

    case result.error
    when nil
      redirect_to close_return_path, notice: "Parking #{@parking_notice.notice_type} cleared."
    when :already_cleared
      redirect_to close_return_path, alert: 'This parking notice has already been cleared.'
    else
      redirect_to close_return_path,
                  alert: 'This parking notice must be cleared by an admin. You can request clearance instead.'
    end
  end

  # Members ask an admin to clear a notice that requires admin clearance.
  def request_clearance
    result = ParkingNotices::RequestClearance.call(notice: @parking_notice, actor: current_user)

    flash_args = case result.error
                 when nil then { notice: 'Clearance requested. An admin will review your request.' }
                 when :already_requested then { notice: 'Clearance has already been requested.' }
                 else { alert: 'This parking notice does not need an admin clearance request.' }
                 end
    redirect_to user_path(current_user, tab: :parking), flash_args
  end

  def print_notice
    printer = Printer.find(params[:printer_id])
    result = print_parking_notice_to_printer(@parking_notice, printer)

    flash_args = case result.error
                 when nil then { notice: "Printed to #{printer.name} (job #{result.job_id})." }
                 when :not_printable then { alert: 'Expired or cleared permits cannot be printed.' }
                 else { alert: "Print failed: #{result.message}" }
                 end
    redirect_to member_parking_permit_path(@parking_notice), flash_args
  end

  # Members may add a note to the history of their own notice.
  def add_note
    result = ParkingNotices::AddNote.call(notice: @parking_notice, actor: current_user, note: params[:note])

    if result.success?
      redirect_to member_parking_permit_path(@parking_notice), notice: 'Note added.'
    else
      redirect_to member_parking_permit_path(@parking_notice), alert: 'Note cannot be blank.'
    end
  end

  private

  # After clearing, return to the list the member was viewing (dashboard or
  # profile parking tab, with any filters). Falls back to the profile parking
  # tab; url_from rejects off-site URLs.
  def close_return_path
    url_from(params[:return_to]) || user_path(current_user, tab: :parking)
  end

  def set_owned_notice
    @parking_notice = ParkingNotice.for_user(current_user).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to user_path(current_user, tab: :parking), alert: 'That parking notice is not available.'
  end

  # Tickets are issued by staff; members may view and clear them (subject to
  # admin-clearance rules) but cannot edit their details.
  def require_owned_permit
    return if @parking_notice.permit?

    redirect_to user_path(current_user, tab: :parking),
                alert: 'Parking ticket details are managed by staff.'
  end

  def member_parking_permit_params
    params.expect(
      parking_notice: %i[description location location_detail expires_at]
    )
  end

  def member_ids_param
    params.dig(:parking_notice, :member_ids)
  end

  # nil when the form left the member list out, so the update leaves members alone.
  def submitted_member_ids
    Array(member_ids_param) if params[:parking_notice]&.key?(:member_ids)
  end
end
