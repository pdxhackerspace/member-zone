# The no-login parking permit form a device-issued email links to. The token reaches exactly one
# permit — the one it creates, or the blank one it completes — and never signs anybody in, so
# everything here works off the link rather than a session.
class ParkingPermitFormsController < ApplicationController
  rate_limit to: 30, within: 1.minute, name: 'parking-permit-form', store: RateLimiting.store,
             with: -> { head :too_many_requests }

  before_action :set_link

  def show
    @parking_notice = @link.parking_notice || default_new_permit
  end

  def update
    unless @link.editable?
      redirect_to parking_permit_form_path(token: params[:token]),
                  alert: 'This link can no longer be used to change the permit.'
      return
    end

    @parking_notice = ParkingPermits::LinkSubmission.call(@link, permit_params)
    if @parking_notice.errors.empty?
      redirect_to parking_permit_form_path(token: params[:token]), notice: 'Your parking permit is saved.'
    else
      render :show, status: :unprocessable_content
    end
  end

  def pdf
    unless @link.printable?
      redirect_to parking_permit_form_path(token: params[:token]), alert: 'This permit can no longer be printed.'
      return
    end

    notice = @link.parking_notice
    send_data ParkingNoticePdf.new(notice).render,
              filename: "parking_permit_#{notice.id}.pdf", type: 'application/pdf', disposition: 'inline'
  end

  private

  # Expired and unknown tokens get the same page, so a guessed token learns nothing.
  def set_link
    @link = ParkingPermitLink.includes(:user, :parking_notice).for_token(params[:token])
    return if @link && !@link.expired?

    render :expired, status: :not_found
  end

  def default_new_permit
    ParkingNotice.new(notice_type: 'permit', expires_at: 7.days.from_now)
  end

  def permit_params
    permitted = %i[description location location_detail]
    permitted << :expires_at if @link.create_permit?
    params.expect(parking_notice: permitted)
  end
end
