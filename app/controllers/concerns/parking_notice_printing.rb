module ParkingNoticePrinting
  extend ActiveSupport::Concern

  private

  # Prints through ParkingNotices::Print and remembers the printer so the next print form
  # preselects it.
  def print_parking_notice_to_printer(parking_notice, printer)
    cookies[:last_printer_id] = { value: printer.id.to_s, expires: 1.year.from_now }
    ParkingNotices::Print.call(notice: parking_notice, printer: printer, layout: params[:layout], actor: current_user)
  end
end
