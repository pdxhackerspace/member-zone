# The no-login page an arrival reminder links to. The token reaches exactly one member's
# place on one notice and never signs anybody in. Opening the page does not clear anything:
# mail scanners follow links, so the clear happens on the button.
class ParkingClearancesController < ApplicationController
  rate_limit to: 30, within: 1.minute, name: 'parking-clearance', store: RateLimiting.store,
             with: -> { head :too_many_requests }

  before_action :set_membership

  def show; end

  def create
    redirect_to parking_clearance_path(token: params[:token]), **clearance_flash
  end

  private

  def clearance_flash
    return { notice: "This #{@notice.notice_type} is already cleared." } if @notice.cleared?
    return clear_notice if @notice.clearable_by?(@member)

    request_clearance
  end

  def clear_notice
    result = ParkingNotices::Clear.call(notice: @notice, actor: @member)
    return { notice: "Parking #{@notice.notice_type} cleared." } if result.success?

    { alert: 'This parking notice could not be cleared.' }
  end

  def request_clearance
    result = ParkingNotices::RequestClearance.call(notice: @notice, actor: @member)
    case result.error
    when nil then { notice: 'Clearance requested. A staff member will take a look.' }
    when :already_requested then { notice: 'Clearance has already been requested.' }
    else { alert: 'This parking notice does not need a clearance request.' }
    end
  end

  # Unknown and expired tokens get the same page, so a guessed token learns nothing.
  def set_membership
    @membership = ParkingNoticeMember.find_by_token_for(:arrival_clearance, params[:token])
    if @membership.nil?
      render :expired, status: :not_found
      return
    end

    @notice = @membership.parking_notice
    @member = @membership.user
  end
end
