class MemberParkingPermitsController < AuthenticatedController
  include ParkingNoticeMemberParams
  include ParkingNoticePrinting

  MAX_MEMBER_PERMIT_DURATION = ParkingNotice::MAX_SELF_SERVICE_DURATION

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
    @parking_notice = ParkingNotice.new(member_parking_permit_params)
    @parking_notice.notice_type = 'permit'
    @parking_notice.issued_by = current_user
    @parking_notice.status = 'active'
    @parking_notice.build_members_from_ids!(resolve_member_permit_member_ids(member_ids_param, current_user))
    validate_member_permit_duration

    if @parking_notice.errors.empty? && @parking_notice.save
      @parking_notice.record_journal_entry!('parking_permit_issued', actor: current_user)
      @parking_notice.notify_issued!
      redirect_to user_path(current_user, tab: :parking), notice: 'Parking permit created successfully.'
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    @parking_notice.event_actor = current_user
    @parking_notice.assign_attributes(member_parking_permit_params)
    validate_member_permit_duration

    if @parking_notice.errors.empty?
      newly_added = []
      begin
        ParkingNotice.transaction do
          @parking_notice.save!
          if params[:parking_notice]&.key?(:member_ids)
            member_ids = resolve_member_permit_member_ids(member_ids_param, current_user, @parking_notice)
            newly_added = @parking_notice.replace_members!(member_ids)
          end
        end
        @parking_notice.notify_issued!(newly_added) if newly_added.any?
        redirect_to user_path(current_user, tab: :parking), notice: 'Parking permit updated.'
      rescue ActiveRecord::RecordInvalid
        render :edit, status: :unprocessable_content
      end
    else
      render :edit, status: :unprocessable_content
    end
  end

  def member_search
    query = params[:q].to_s.strip
    users = if query.length >= 1
              member_pickable_for_member(current_user)
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
    if @parking_notice.cleared?
      redirect_to close_return_path, alert: 'This parking notice has already been cleared.'
      return
    end

    unless @parking_notice.clearable_by?(current_user)
      redirect_to close_return_path,
                  alert: 'This parking notice must be cleared by an admin. You can request clearance instead.'
      return
    end

    @parking_notice.event_actor = current_user
    @parking_notice.clear!(current_user)
    @parking_notice.record_journal_entry!('parking_notice_cleared', actor: current_user)
    redirect_to close_return_path,
                notice: "Parking #{@parking_notice.notice_type} cleared."
  end

  # Members ask an admin to clear a notice that requires admin clearance.
  def request_clearance
    if @parking_notice.cleared? || !@parking_notice.requires_admin_clearance?
      redirect_to user_path(current_user, tab: :parking),
                  alert: 'This parking notice does not need an admin clearance request.'
      return
    end

    if @parking_notice.clearance_requested?
      redirect_to user_path(current_user, tab: :parking), notice: 'Clearance has already been requested.'
      return
    end

    @parking_notice.request_clearance!(current_user)
    redirect_to user_path(current_user, tab: :parking),
                notice: 'Clearance requested. An admin will review your request.'
  end

  def print_notice
    unless @parking_notice.active?
      redirect_to member_parking_permit_path(@parking_notice),
                  alert: 'Expired or cleared permits cannot be printed.'
      return
    end

    printer = Printer.find(params[:printer_id])
    job_id = print_parking_notice_to_printer(@parking_notice, printer)

    redirect_to member_parking_permit_path(@parking_notice),
                notice: "Printed to #{printer.name} (job #{job_id})."
  rescue CupsService::PrintError => e
    redirect_to member_parking_permit_path(@parking_notice),
                alert: "Print failed: #{e.message}"
  end

  # Members may add a note to the history of their own notice.
  def add_note
    note = params[:note].to_s.strip

    if note.blank?
      redirect_to member_parking_permit_path(@parking_notice), alert: 'Note cannot be blank.'
      return
    end

    @parking_notice.log_event!('note', actor: current_user, note: note)
    redirect_to member_parking_permit_path(@parking_notice), notice: 'Note added.'
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

  def validate_member_permit_duration
    return if @parking_notice.expires_at.blank?
    # Staff extensions and legacy permits may expire after the self-service cap;
    # members may edit other fields without touching expiration.
    return if @parking_notice.persisted? && !member_changed_expires_at?

    return if @parking_notice.expires_at <= member_permit_max_expires_at

    @parking_notice.errors.add(:expires_at, 'must be within 2 weeks')
  end

  def member_changed_expires_at?
    new_at = @parking_notice.expires_at
    old_at = @parking_notice.expires_at_in_database
    return true if old_at.nil?

    member_expires_at_minute(new_at) != member_expires_at_minute(old_at)
  end

  def member_expires_at_minute(time)
    time.in_time_zone.change(sec: 0, usec: 0)
  end

  def member_permit_max_expires_at
    anchor = @parking_notice.persisted? ? @parking_notice.created_at : Time.current
    anchor + MAX_MEMBER_PERMIT_DURATION
  end
end
